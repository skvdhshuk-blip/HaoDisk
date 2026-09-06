import Foundation
import SQLite3

struct DirectoryKey: Hashable, Sendable {
    let version: UUID
    let directoryID: Int
    let metric: SizeMetric
    let sort: DirectorySort
    var revision: Int = 0
}
struct MapKey: Hashable, Sendable {
    let version: UUID
    let directoryID: Int
    let metric: SizeMetric
    var revision: Int = 0
}
struct MapEntry: Identifiable, Sendable {
    let id: Int
    let name: String
    let capacity: String
    let tooltip: String
    let bytes: Int64
    let colorIndex: Int
    var accessibilityLabel: String { "\(name)，\(capacity)" }
}
struct MapPresentation: Sendable {
    let key: MapKey
    let entries: [MapEntry]
    let remainingFirstID: Int?
    var weights: [MapWeight] { entries.map { MapWeight(id: $0.id, value: Double($0.bytes)) } }
}
struct DirectoryPresentation: Sendable {
    let key: DirectoryKey
    let directory: DiskNode
    let ancestors: [DiskNode]
    let rowCount: Int
    var pages: [Int: [Int: DiskNode]]
    var pageOrder: [Int]
    var rowByID: [Int: Int]
    let mapNodes: [DiskNode]
    let map: MapPresentation
    var pageVersion = UUID()
    var loadedCount: Int { pages.values.reduce(0) { $0 + $1.count } }
    var rowIDs: [Int] { pages.values.flatMap { $0 }.sorted { $0.key < $1.key }.map { $0.value.id } }
    var nodes: [Int: DiskNode] {
        var result = Dictionary(uniqueKeysWithValues: ancestors.map { ($0.id, $0) })
        for node in mapNodes { result[node.id] = node }
        for page in pages.values { for node in page.values { result[node.id] = node } }
        return result
    }
    func node(at row: Int) -> DiskNode? { pages[row / 512]?[row] }

    static func prepare(_ snapshot: DiskSnapshot, directoryID: Int, metric: SizeMetric, sort: DirectorySort,
                        cancelled: () -> Bool = { Task.isCancelled }) throws -> DirectoryPresentation {
        try snapshot.index.access {
            let index = snapshot.index
            guard let directory = try index.node(directoryID) else { throw CleanupError.refused("目录已移除。") }
            let key = DirectoryKey(version: snapshot.version, directoryID: directoryID, metric: metric, sort: sort, revision: directory.revision)
            try index.prepareOrdering(directory: directory, metric: metric, sort: sort, cancelled: cancelled)
            let column = metric == .allocated ? "allocated" : "logical"
            var top: [DiskNode] = []
            try index.rows("SELECT * FROM nodes WHERE parent=? AND \(column)>0 ORDER BY \(column) DESC,id LIMIT 81", [.int(Int64(directoryID))]) { top.append(ScanIndex.decode($0)) }
            let total = directory.bytes(metric)
            var entries = top.prefix(80).map { node in
                let capacity = nodeSizeLabel(node, metric: metric)
                let hash = node.name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
                let share = percentage(node.bytes(metric), total: total) + (directory.state != .complete ? "（已读空间）" : "")
                return MapEntry(id: node.id, name: node.name, capacity: capacity,
                                tooltip: "\(node.name)\n\(capacity)\n\(share)" + (node.state != .complete ? "\n未完整读取" : ""), bytes: node.bytes(metric), colorIndex: Int(hash % 6))
            }
            if top.count > 80 {
                let count = try index.integer("SELECT COUNT(*) FROM nodes WHERE parent=? AND \(column)>0", [.int(Int64(directoryID))]) - 80
                let bytes = total - entries.reduce(0) { $0 + $1.bytes }
                let capacity = (directory.state != .complete ? "已读 " : "") + formattedBytes(bytes)
                let name = "其余 \(count) 项"
                entries.append(MapEntry(id: -1, name: name, capacity: capacity, tooltip: "\(name) · \(capacity)\n在列表中查看", bytes: bytes, colorIndex: 0))
            }
            var view = DirectoryPresentation(key: key, directory: directory, ancestors: try index.ancestors(directoryID), rowCount: directory.childCount,
                pages: [:], pageOrder: [], rowByID: [:], mapNodes: top,
                map: MapPresentation(key: MapKey(version: snapshot.version, directoryID: directoryID, metric: metric, revision: directory.revision), entries: entries, remainingFirstID: top.count > 80 ? top.last?.id : nil))
            for node in top { view.rowByID[node.id] = try index.row(node.id, key: key) }
            try view.loadPages(around: 0, index: index)
            if cancelled() { throw CancellationError() }
            return view
        }
    }

    mutating func loadPages(around row: Int, index: ScanIndex) throws {
        let page = max(0, row / 512)
        var changed = false
        for number in [page, page + 1, page - 1] where number >= 0 && number * 512 < rowCount {
            if pages[number] == nil {
                let values = try index.page(key, start: number * 512)
                pages[number] = values
                for (row, node) in values { rowByID[node.id] = row }
                changed = true
            }
            pageOrder.removeAll { $0 == number }; pageOrder.append(number)
        }
        while pageOrder.count > 8 {
            let oldest = pageOrder.removeFirst()
            if let removed = pages.removeValue(forKey: oldest) {
                for node in removed.values where !mapNodes.contains(where: { $0.id == node.id }) { rowByID.removeValue(forKey: node.id) }
            }
            changed = true
        }
        if changed { pageVersion = UUID() }
    }
}

actor DirectoryCache {
    private let maximumViews: Int
    private let maximumRowIDs: Int
    private var version: UUID?
    private var entries: [DirectoryKey: DirectoryPresentation] = [:]
    private var order: [DirectoryKey] = []
    private(set) var retainedRowIDs = 0
    private(set) var preparationCount = 0
    var entryCount: Int { entries.count }
    init(maximumViews: Int = 16, maximumRowIDs: Int = 500_000) { self.maximumViews = maximumViews; self.maximumRowIDs = maximumRowIDs }
    func reset(version: UUID? = nil, seed: DirectoryPresentation? = nil) {
        entries.removeAll(); order.removeAll(); retainedRowIDs = 0; self.version = version
        if let seed { insert(seed) }
    }
    func value(for snapshot: DiskSnapshot, directoryID: Int, metric: SizeMetric, sort: DirectorySort, row: Int = 0, selecting: Int? = nil) throws -> DirectoryPresentation {
        try Task.checkCancellation()
        return try snapshot.index.access {
            if version != snapshot.version { reset(version: snapshot.version) }
            guard let directory = try snapshot.index.node(directoryID) else { throw CleanupError.refused("目录已移除。") }
            let key = DirectoryKey(version: snapshot.version, directoryID: directoryID, metric: metric, sort: sort, revision: directory.revision)
            var value: DirectoryPresentation
            if let cached = entries[key] { value = cached }
            else { value = try DirectoryPresentation.prepare(snapshot, directoryID: directoryID, metric: metric, sort: sort); preparationCount += 1 }
            let target = try selecting.flatMap { try snapshot.index.row($0, key: key) } ?? row
            try value.loadPages(around: target, index: snapshot.index)
            try Task.checkCancellation()
            // A revised directory replaces its obsolete cache entries, retaining unrelated views.
            for old in order where old.directoryID == directoryID && old.revision != key.revision { remove(old) }
            insert(value)
            return value
        }
    }
    private func remove(_ key: DirectoryKey) {
        if let value = entries.removeValue(forKey: key) { retainedRowIDs -= value.loadedCount }
        order.removeAll { $0 == key }
    }
    private func insert(_ value: DirectoryPresentation) {
        remove(value.key)
        guard maximumViews > 0, value.loadedCount <= maximumRowIDs else { return }
        entries[value.key] = value; order.append(value.key); retainedRowIDs += value.loadedCount
        while entries.count > maximumViews || retainedRowIDs > maximumRowIDs { remove(order[0]) }
    }
}

struct ScanRestoration: Sendable {
    var currentPath: String?
    var selectedPath: String?
    var history: [String] = []
    var future: [String] = []
    var queue: [String] = []
}
struct PreparedScan: Sendable {
    let snapshot: DiskSnapshot
    let presentation: DirectoryPresentation
    let selectedID: Int?
    let history: [Int]
    let future: [Int]
    let queue: Set<Int>
    let retainedNodes: [Int: DiskNode]
    static func prepare(_ snapshot: DiskSnapshot, restoration: ScanRestoration = ScanRestoration(), metric: SizeMetric, sort: DirectorySort) throws -> PreparedScan {
        try snapshot.index.access {
            var restored: [String: DiskNode] = [:]
            let wanted = Set(restoration.history + restoration.future + restoration.queue + [restoration.currentPath, restoration.selectedPath].compactMap { $0 })
            for path in wanted { restored[path] = try snapshot.index.node(path: path) }
            var path = restoration.currentPath
            while let value = path, restored[value] == nil, value != snapshot.root.url.path, value.hasPrefix(snapshot.root.url.path + "/") {
                path = URL(fileURLWithPath: value).deletingLastPathComponent().path
                if let path { restored[path] = try snapshot.index.node(path: path) }
            }
            let current = path.flatMap { restored[$0]?.id } ?? 0
            var view = try DirectoryPresentation.prepare(snapshot, directoryID: current, metric: metric, sort: sort, cancelled: { false })
            let selection = restoration.selectedPath.flatMap { restored[$0]?.id }
            if let selection, let row = try snapshot.index.row(selection, key: view.key) { try view.loadPages(around: row, index: snapshot.index) }
            return PreparedScan(snapshot: snapshot, presentation: view, selectedID: selection,
                history: restoration.history.compactMap { restored[$0]?.id }, future: restoration.future.compactMap { restored[$0]?.id },
                queue: Set(restoration.queue.compactMap { restored[$0] }.filter { $0.restriction == nil }.map(\.id)),
                retainedNodes: Dictionary(uniqueKeysWithValues: restored.values.map { ($0.id, $0) }))
        }
    }
}
