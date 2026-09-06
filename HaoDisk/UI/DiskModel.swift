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

struct DirectoryDisplay: Sendable {
    let snapshot: DiskSnapshot
    let presentation: DirectoryPresentation
    let nodes: [Int: DiskNode]
    init(snapshot: DiskSnapshot, presentation: DirectoryPresentation, retained: [Int: DiskNode] = [:]) {
        self.snapshot = snapshot; self.presentation = presentation
        self.nodes = retained.merging(presentation.nodes) { _, new in new }
    }
}

@MainActor
final class ScanProgressModel: ObservableObject {
    @Published private(set) var value = ScanProgress(count: 0, bytes: 0, folder: "准备扫描")
    func update(_ value: ScanProgress) {
        if self.value != value { self.value = value }
    }
}

@MainActor
final class DiskModel: ObservableObject {
    @Published private(set) var display: DirectoryDisplay?
    @Published var volumeCapacity: VolumeCapacity?
    @Published var selectedID: Int? {
        didSet {
            if let oldValue, oldValue != currentID, !basket.contains(oldValue), !history.contains(oldValue), !future.contains(oldValue) {
                retainedNodes.removeValue(forKey: oldValue)
            }
            if let selectedID, let node = nodes[selectedID] { retainedNodes[selectedID] = node }
        }
    }
    @Published var metric: SizeMetric = .allocated { didSet { if oldValue != metric { refreshDirectory() } } }
    @Published var sort: DirectorySort = .sizeDescending { didSet { if oldValue != sort { refreshDirectory() } } }
    @Published private(set) var isLoadingDirectory = false
    let scanProgress = ScanProgressModel()
    let directoryCache = DirectoryCache()
    @Published var visualMode = true
    @Published var showInspector = false
    @Published var showResults = false
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
    private var worker: Task<PreparedScan, Error>?
    private var scanID = UUID()
    private var history: [Int] = []
    private var future: [Int] = []
    private var directoryTask: Task<Void, Never>?
    private var directoryRequest = UUID()
    private var pendingID: Int?
    private var retainedNodes: [Int: DiskNode] = [:]
    private var pageTask: Task<Void, Never>?
    private var requestedPage: Int?
    @Published private(set) var cleanupInvalid = false
    var nodes: [Int: DiskNode] { display?.nodes ?? [:] }

    var snapshot: DiskSnapshot? { display?.snapshot }
    var presentation: DirectoryPresentation? { display?.presentation }
    var currentID: Int { presentation?.key.directoryID ?? 0 }
    var displayedMetric: SizeMetric { presentation?.key.metric ?? metric }
    var isBrowsingBusy: Bool { isBusy || isLoadingDirectory }

    var isBusy: Bool { isScanning || isCleaning || isChoosing }
    var hasAccess: Bool { access != nil }
    var rootFolderName: String { access?.url.lastPathComponent ?? "文件夹" }
    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !future.isEmpty }
    var current: DiskNode? { presentation?.directory }
    var selected: DiskNode? { selectedID.flatMap { nodes[$0] } }
    var directoryCount: Int { presentation?.rowCount ?? 0 }
    var basketNodes: [DiskNode] { basket.sorted().compactMap { nodes[$0] } }
    var basketBytes: Int64 { basketNodes.reduce(0) { $0 + $1.bytes(metric) } }

    private func cancelDirectory() {
        directoryTask?.cancel()
        pageTask?.cancel(); requestedPage = nil
        directoryRequest = UUID()
        pendingID = nil
        isLoadingDirectory = false
    }

    private func refreshDirectory() {
        requestDirectory(pendingID ?? currentID, selecting: selectedID)
    }

    private func requestDirectory(_ id: Int, selecting selection: Int? = nil) {
        guard let snapshot else { return }
        directoryTask?.cancel()
        let token = UUID()
        directoryRequest = token
        pendingID = id
        isLoadingDirectory = true
        let keep = Set(history + future).union(basket).union([currentID, id]).union(selectedID.map { [$0] } ?? [])
        retainedNodes = retainedNodes.filter { keep.contains($0.key) }
        let metric = metric, sort = sort
        directoryTask = Task {
            do {
                let value = try await directoryCache.value(for: snapshot, directoryID: id, metric: metric, sort: sort, selecting: selection)
                guard !Task.isCancelled, directoryRequest == token, self.snapshot?.version == snapshot.version else { return }
                display = DirectoryDisplay(snapshot: snapshot, presentation: value, retained: retainedNodes)
                selectedID = selection.flatMap { value.rowByID[$0] == nil ? nil : $0 }
            } catch is CancellationError {
                // A newer directory request owns the display.
            } catch { if directoryRequest == token { message = error.localizedDescription } }
            guard directoryRequest == token else { return }
            pendingID = nil
            isLoadingDirectory = false
        }
    }

    func waitForDirectory() async { await directoryTask?.value }

    func install(_ result: PreparedScan) async {
        cancelDirectory()
        await directoryCache.reset(version: result.snapshot.version, seed: result.presentation)
        selectedID = nil
        basket = []
        retainedNodes = result.retainedNodes
        cleanupInvalid = false
        display = DirectoryDisplay(snapshot: result.snapshot, presentation: result.presentation, retained: retainedNodes)
        selectedID = result.selectedID
        history = result.history
        future = result.future
        basket = result.queue
    }

    func node(for id: Int, version: UUID) -> DiskNode? {
        guard snapshot?.version == version else { return nil }
        return nodes[id]
    }

    @discardableResult
    func select(_ id: Int, version: UUID) -> Bool {
        guard !isBrowsingBusy, node(for: id, version: version) != nil else { return false }
        selectedID = id
        return true
    }

    func selectOffset(_ offset: Int) {
        guard !isBrowsingBusy, let presentation, presentation.rowCount > 0 else { return }
        let index = selectedID.flatMap { presentation.rowByID[$0] }
        let next = index.map { min(presentation.rowCount - 1, max(0, $0 + offset)) } ?? (offset > 0 ? 0 : presentation.rowCount - 1)
        if let node = presentation.node(at: next) { selectedID = node.id }
        else { loadPage(at: next, selectRow: true) }
    }

    func loadPage(at row: Int, selectRow: Bool = false) {
        guard !isBrowsingBusy, let snapshot, let presentation, row >= 0, row < presentation.rowCount else { return }
        let page = row / 512
        let wanted = [page - 1, page, page + 1].filter { $0 >= 0 && $0 * 512 < presentation.rowCount }
        if wanted.allSatisfy({ presentation.pages[$0] != nil }) {
            if selectRow { selectedID = presentation.node(at: row)?.id }
            return
        }
        guard requestedPage != page else { return }
        pageTask?.cancel(); requestedPage = page
        let key = presentation.key
        pageTask = Task {
            defer { if requestedPage == page { requestedPage = nil } }
            do {
                let value = try await directoryCache.value(for: snapshot, directoryID: key.directoryID, metric: key.metric, sort: key.sort, row: row)
                guard !Task.isCancelled, self.presentation?.key == key else { return }
                display = DirectoryDisplay(snapshot: snapshot, presentation: value, retained: retainedNodes)
                if selectRow { selectedID = value.node(at: row)?.id }
            } catch is CancellationError {} catch { message = error.localizedDescription }
        }
    }

    func openSelected() {
        guard !isBrowsingBusy, let selected else { return }
        if selected.canNavigate { navigate(selected.id) } else { showInspector = true }
    }

    var selectedCleanupReason: String? {
        guard let selected else { return nil }
        return cleanupInvalid ? "分析结果已失效，请重新扫描。" : CleanupPolicy.reason(for: selected.id, in: nodes)
    }

    func reviewSelected() {
        guard let selected, !isBrowsingBusy, selectedCleanupReason == nil else { return }
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
        cancelDirectory()
        display = nil
        retainedNodes = [:]; cleanupInvalid = false
        Task { await directoryCache.reset() }
        volumeCapacity = nil
        basket = []
        selectedID = nil
        history = []; future = []
    }

    func scan(preservingOutcomes: Bool = false) {
        guard !isBusy, let url = access?.url else { return }
        let sameRoot = snapshot?.root.url == url
        let restoration = ScanRestoration(
            currentPath: sameRoot ? current?.url.path : nil,
            selectedPath: sameRoot ? selected?.url.path : nil,
            history: sameRoot ? history.compactMap { nodes[$0]?.url.path } : [],
            future: sameRoot ? future.compactMap { nodes[$0]?.url.path } : [],
            queue: sameRoot ? (preservingOutcomes ? outcomes.filter { $0.error != nil }.map { $0.url.path } : basketNodes.map { $0.url.path }) : [])
        cancelDirectory()
        display = nil; retainedNodes = [:]; selectedID = nil
        isScanning = true
        basket = []
        showInspector = false
        showReview = false
        if !sameRoot {
            display = nil; selectedID = nil
            volumeCapacity = nil
            history = []; future = []
        }
        if !preservingOutcomes { outcomes = [] }
        scanProgress.update(ScanProgress(count: 0, bytes: 0, folder: url.lastPathComponent))
        let token = UUID()
        scanID = token
        let metric = metric, sort = sort
        let (updates, continuation) = AsyncStream<ScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task {
            for await value in updates {
                guard scanID == token, isScanning else { continue }
                scanProgress.update(value)
            }
        }
        let job = Task.detached(priority: .userInitiated) { [self] in
            defer { continuation.finish() }
            await self.directoryCache.reset()
            let capacity = VolumeCapacity.read(at: url)
            await MainActor.run {
                guard self.scanID == token else { return }
                self.volumeCapacity = capacity
            }
            let snapshot = try DiskScanner().scan(url, cancelled: { Task.isCancelled }) { continuation.yield($0) }
            return try PreparedScan.prepare(snapshot, restoration: restoration, metric: metric, sort: sort)
        }
        worker = job
        Task {
            do {
                let result = try await job.value
                guard scanID == token else { return }
                await install(result)
                volumeCapacity = VolumeCapacity(total: result.snapshot.totalCapacity, available: result.snapshot.availableCapacity)
                if self.metric != metric || self.sort != sort { refreshDirectory() }
            } catch { message = error.localizedDescription }
            isScanning = false
            worker = nil
        }
    }

    func cancelScan() { worker?.cancel() }

    func navigate(_ id: Int) {
        guard !isBusy, let node = nodes[id], node.canNavigate,
              (pendingID ?? currentID) != id else { return }
        if let current { retainedNodes[current.id] = current }
        retainedNodes[node.id] = node
        history.append(pendingID ?? currentID)
        future = []
        selectedID = nil
        showInspector = false
        requestDirectory(id)
    }

    func back() {
        guard !isBusy, let id = history.popLast() else { return }
        future.append(pendingID ?? currentID)
        selectedID = nil; showInspector = false
        requestDirectory(id)
    }

    func forward() {
        guard !isBusy, let id = future.popLast() else { return }
        history.append(pendingID ?? currentID)
        selectedID = nil; showInspector = false
        requestDirectory(id)
    }

    func up() {
        if let id = nodes[pendingID ?? currentID]?.parent { navigate(id) }
    }

    func reveal(_ node: DiskNode) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }

    func add(_ node: DiskNode) {
        guard !isBrowsingBusy, !cleanupInvalid else { return }
        if let reason = CleanupPolicy.reason(for: node.id, in: nodes) { message = reason; return }
        retainedNodes[node.id] = node
        basket = CleanupPolicy.adding(node, to: basket, nodes: nodes)
    }

    func trashReviewedItems() {
        guard !isBrowsingBusy, !cleanupInvalid, let snapshot, !basket.isEmpty else { return }
        let ids = basket
        let restoration = ScanRestoration(currentPath: current?.url.path, selectedPath: selected?.url.path,
            history: history.compactMap { nodes[$0]?.url.path }, future: future.compactMap { nodes[$0]?.url.path }, queue: basketNodes.map { $0.url.path })
        let metric = metric, sort = sort
        isCleaning = true
        cancelDirectory()
        Task {
            let result = await Task.detached(priority: .userInitiated) { TrashService().move(ids, in: snapshot) }.value
            outcomes = result.outcomes
            volumeCapacity = VolumeCapacity(total: result.snapshot.totalCapacity, available: result.snapshot.availableCapacity)
            if let error = result.updateError {
                cleanupInvalid = true
                message = error
                basket.subtract(result.outcomes.filter { $0.error == nil }.map(\.id))
            } else {
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try PreparedScan.prepare(result.snapshot, restoration: restoration, metric: metric, sort: sort)
                    }.value
                    // Keep the session and unrelated directory caches after a local edit.
                    retainedNodes = prepared.retainedNodes
                    selectedID = nil
                    display = DirectoryDisplay(snapshot: prepared.snapshot, presentation: prepared.presentation, retained: retainedNodes)
                    selectedID = prepared.selectedID
                    history = prepared.history; future = prepared.future; basket = prepared.queue
                } catch { cleanupInvalid = true; message = "清理已完成，分析更新失败。请重新扫描。\n\(error.localizedDescription)" }
            }
            isCleaning = false
            showReview = false
        }
    }
}
