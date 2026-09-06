import AppKit
import SwiftUI

private final class FolderAccess {
    let url: URL

    init(data: Data) throws {
        var stale = false
        url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                      relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else {
            throw CleanupError.refused("授权已失效，请重新选择文件夹。")
        }
    }

    deinit { url.stopAccessingSecurityScopedResource() }
}

@MainActor
final class DiskModel: ObservableObject {
    @Published var snapshot: DiskSnapshot?
    @Published var currentID = 0 { didSet { refreshChildren() } }
    @Published var selectedID: Int? { didSet { refreshSelection() } }
    @Published var metric: SizeMetric = .allocated { didSet { refreshChildren() } }
    @Published var sort: DirectorySort = .sizeDescending { didSet { refreshChildren() } }
    @Published private(set) var children: [DiskNode] = []
    @Published var visualMode = true
    @Published var showInspector = false
    @Published var showResults = false
    @Published var progress = ScanProgress(count: 0, bytes: 0, folder: "准备扫描")
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var isChoosing = false
    @Published var basket: Set<Int> = []
    @Published var showReview = false
    @Published var showIssues = false
    @Published var showHelp = false
    @Published var message: String?
    @Published var outcomes: [TrashOutcome] = []
    @Published var hasBookmark = UserDefaults.standard.data(forKey: "selectedFolderBookmark") != nil
    private var access: FolderAccess?
    private var worker: Task<DiskSnapshot, Error>?
    private var scanID = UUID()
    private var history: [Int] = []
    private var future: [Int] = []
    private var selectionRestriction: String?

    var isBusy: Bool { isScanning || isCleaning || isChoosing }
    var hasAccess: Bool { access != nil }
    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !future.isEmpty }
    var current: DiskNode? { snapshot?.nodes[currentID] }
    var selected: DiskNode? {
        guard let snapshot, let selectedID, snapshot.nodes.indices.contains(selectedID) else { return nil }
        return snapshot.nodes[selectedID]
    }
    var directoryCount: Int { current?.children.count ?? 0 }
    var basketNodes: [DiskNode] { basket.sorted().compactMap { snapshot?.nodes[$0] } }
    var basketBytes: Int64 { basketNodes.reduce(0) { $0 + $1.bytes(metric) } }

    private func refreshChildren() {
        guard let snapshot, snapshot.nodes.indices.contains(currentID) else { children = []; return }
        children = snapshot.children(of: currentID, metric: metric, sort: sort)
    }

    func selectOffset(_ offset: Int) {
        guard !isBusy, !children.isEmpty else { return }
        let index = selectedID.flatMap { id in children.firstIndex { $0.id == id } }
        let next = index.map { min(children.count - 1, max(0, $0 + offset)) } ?? (offset > 0 ? 0 : children.count - 1)
        selectedID = children[next].id
    }

    func openSelected() {
        guard !isBusy, let selected else { return }
        if selected.canNavigate { navigate(selected.id) } else { showInspector = true }
    }

    private func refreshSelection() {
        guard let snapshot, let selected else { selectionRestriction = nil; return }
        selectionRestriction = CleanupPolicy.reason(for: selected.id, in: snapshot)
    }
    var selectedCleanupReason: String? { selectionRestriction }

    func reviewSelected() {
        guard let selected, !isBusy, selectedCleanupReason == nil else { return }
        add(selected)
        showReview = true
    }

    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = current?.url ?? access?.url
        panel.title = "选择要分析的文件夹"
        panel.message = "HaoDisk 只分析你选择的目录。清理前需要你确认，所有处理均在本机进行。"
        panel.prompt = "授权并分析"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        isChoosing = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isChoosing = false
                guard response == .OK, let url = panel.url else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let data = try url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil, relativeTo: nil)
                    try self.activate(data)
                    self.scan()
                } catch { self.message = error.localizedDescription }
            }
        }
    }

    private func activate(_ data: Data) throws {
        let grant = try FolderAccess(data: data)
        // Always renew after resolving while the scope is active, including stale bookmarks.
        let renewed = try grant.url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
        access = grant
        UserDefaults.standard.set(renewed, forKey: "selectedFolderBookmark")
        hasBookmark = true
    }

    func restoreFolder() {
        guard !isBusy, let data = UserDefaults.standard.data(forKey: "selectedFolderBookmark") else { return }
        do {
            try activate(data)
            scan()
        } catch { message = "无法恢复上次授权。请重新选择文件夹。\n\(error.localizedDescription)" }
    }

    func forgetFolder() {
        guard !isBusy else { return }
        UserDefaults.standard.removeObject(forKey: "selectedFolderBookmark")
        hasBookmark = false
        access = nil
        snapshot = nil
        children = []
        basket = []
        selectedID = nil
        currentID = 0
        history = []; future = []
    }

    func scan(preservingOutcomes: Bool = false) {
        guard !isBusy, let url = access?.url else { return }
        let sameRoot = snapshot?.root.url == url.resolvingSymlinksInPath().standardizedFileURL
        let currentPath = sameRoot ? current?.url.path : nil
        let selectedPath = sameRoot ? selected?.url.path : nil
        let oldHistory = sameRoot ? history.compactMap { snapshot?.nodes[$0].url.path } : []
        let oldFuture = sameRoot ? future.compactMap { snapshot?.nodes[$0].url.path } : []
        let oldQueue = sameRoot ? (preservingOutcomes ? outcomes.filter { $0.error != nil }.map { $0.url.path } : basketNodes.map { $0.url.path }) : []
        isScanning = true
        basket = []
        showInspector = false
        showReview = false
        if !sameRoot {
            snapshot = nil; children = []; selectedID = nil
            currentID = 0; history = []; future = []
        }
        if !preservingOutcomes { outcomes = [] }
        progress = ScanProgress(count: 0, bytes: 0, folder: url.lastPathComponent)
        let token = UUID()
        scanID = token
        let job = Task.detached(priority: .userInitiated) { [self] in
            try DiskScanner().scan(url, cancelled: { Task.isCancelled }) { value in
                Task { @MainActor in
                    guard self.scanID == token, self.isScanning else { return }
                    self.progress = value
                }
            }
        }
        worker = job
        Task {
            do {
                let result = try await job.value
                guard scanID == token else { return }
                snapshot = result
                let wanted = Set(oldHistory + oldFuture + oldQueue + [currentPath, selectedPath].compactMap { $0 })
                var restored: [String: Int] = [:]
                for node in result.nodes where wanted.contains(node.url.path) { restored[node.url.path] = node.id }
                currentID = currentPath.flatMap { restored[$0] } ?? 0
                selectedID = selectedPath.flatMap { restored[$0] }
                history = oldHistory.compactMap { restored[$0] }
                future = oldFuture.compactMap { restored[$0] }
                basket = Set(oldQueue.compactMap { restored[$0] }.filter { CleanupPolicy.reason(for: $0, in: result) == nil })
                refreshChildren()
            } catch { message = error.localizedDescription }
            isScanning = false
            worker = nil
        }
    }

    func cancelScan() { worker?.cancel() }

    func navigate(_ id: Int) {
        guard !isBusy, let node = snapshot?.nodes[id], node.canNavigate, currentID != id else { return }
        history.append(currentID)
        future = []
        currentID = id
        selectedID = nil
        showInspector = false
    }

    func back() {
        guard !isBusy, let id = history.popLast() else { return }
        future.append(currentID); currentID = id; selectedID = nil; showInspector = false
    }

    func forward() {
        guard !isBusy, let id = future.popLast() else { return }
        history.append(currentID); currentID = id; selectedID = nil; showInspector = false
    }

    func up() { if let id = current?.parent { navigate(id) } }

    func reveal(_ node: DiskNode) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }

    func add(_ node: DiskNode) {
        guard !isBusy, let snapshot else { return }
        if let reason = CleanupPolicy.reason(for: node.id, in: snapshot) { message = reason; return }
        basket = CleanupPolicy.adding(node.id, to: basket, in: snapshot)
    }

    func trashReviewedItems() {
        guard !isBusy, let snapshot, !basket.isEmpty else { return }
        let ids = basket
        isCleaning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                TrashService().move(ids, in: snapshot)
            }.value
            outcomes = result
            isCleaning = false
            showReview = false
            scan(preservingOutcomes: true)
        }
    }
}

func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
