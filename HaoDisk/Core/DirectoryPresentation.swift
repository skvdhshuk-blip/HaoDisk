import Foundation

struct DirectoryKey: Hashable, Sendable {
    let version: UUID
    let directoryID: Int
    let metric: SizeMetric
    let sort: DirectorySort
}

struct MapKey: Hashable, Sendable {
    let version: UUID
    let directoryID: Int
    let metric: SizeMetric
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
    let rowIDs: [Int]
    let rowByID: [Int: Int]
    let map: MapPresentation

    static func prepare(_ snapshot: DiskSnapshot, directoryID: Int, metric: SizeMetric, sort: DirectorySort,
                        cancelled: () -> Bool = { Task.isCancelled }) throws -> DirectoryPresentation {
        func check() throws { if cancelled() { throw CancellationError() } }
        try check()
        // Extract comparison keys once; URL parsing never occurs inside the sort comparator.
        var items: [(id: Int, name: String, bytes: Int64)] = []
        items.reserveCapacity(snapshot.nodes[directoryID].children.count)
        for (offset, id) in snapshot.nodes[directoryID].children.enumerated() {
            if offset % 1024 == 0 { try check() }
            let node = snapshot.nodes[id]
            items.append((id, node.name, node.bytes(metric)))
        }
        var comparisons = 0
        try items.sort { a, b in
            comparisons += 1
            if comparisons % 1024 == 0 { try check() }
            if !sort.byName && a.bytes != b.bytes { return sort.ascending ? a.bytes < b.bytes : a.bytes > b.bytes }
            let order = a.name.localizedStandardCompare(b.name)
            return sort == .nameDescending ? order == .orderedDescending : order == .orderedAscending
        }
        let rows = items.map(\.id)
        let rowByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element, $0.offset) })
        var ranked = items.filter { $0.bytes > 0 }
        try ranked.sort { a, b in
            comparisons += 1
            if comparisons % 1024 == 0 { try check() }
            return a.bytes == b.bytes ? a.id < b.id : a.bytes > b.bytes
        }
        let total = snapshot.nodes[directoryID].bytes(metric)
        var entries = ranked.prefix(80).map { item in
            let node = snapshot.nodes[item.id]
            let capacity = nodeSizeLabel(node, metric: metric)
            let hash = item.name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            return MapEntry(id: item.id, name: item.name, capacity: capacity,
                            tooltip: "\(item.name)\n\(capacity)\n" + (node.issueCount > 0 ? "未完整读取" : percentage(item.bytes, total: total)),
                            bytes: item.bytes, colorIndex: Int(hash % 6))
        }
        let rest = ranked.dropFirst(80)
        if !rest.isEmpty {
            let bytes = rest.reduce(Int64(0)) { $0 + $1.bytes }
            let capacity = (rest.contains { snapshot.nodes[$0.id].issueCount > 0 } ? "已读 " : "") + formattedBytes(bytes)
            let name = "其余 \(rest.count) 项"
            entries.append(MapEntry(id: -1, name: name, capacity: capacity, tooltip: "\(name) · \(capacity)\n在列表中查看", bytes: bytes, colorIndex: 0))
        }
        try check()
        return DirectoryPresentation(key: DirectoryKey(version: snapshot.version, directoryID: directoryID, metric: metric, sort: sort),
                                     rowIDs: rows, rowByID: rowByID,
                                     map: MapPresentation(key: MapKey(version: snapshot.version, directoryID: directoryID, metric: metric), entries: entries, remainingFirstID: rest.first?.id))
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

    init(maximumViews: Int = 16, maximumRowIDs: Int = 500_000) {
        self.maximumViews = maximumViews
        self.maximumRowIDs = maximumRowIDs
    }

    func reset(version: UUID? = nil, seed: DirectoryPresentation? = nil) {
        entries.removeAll(); order.removeAll(); retainedRowIDs = 0
        self.version = version
        if let seed { insert(seed) }
    }

    func value(for snapshot: DiskSnapshot, directoryID: Int, metric: SizeMetric, sort: DirectorySort) throws -> DirectoryPresentation {
        try Task.checkCancellation()
        if version != snapshot.version { reset(version: snapshot.version) }
        let key = DirectoryKey(version: snapshot.version, directoryID: directoryID, metric: metric, sort: sort)
        if let cached = entries[key] {
            touch(key)
            return cached
        }
        let value = try DirectoryPresentation.prepare(snapshot, directoryID: directoryID, metric: metric, sort: sort)
        preparationCount += 1
        try Task.checkCancellation()
        insert(value)
        return value
    }

    private func touch(_ key: DirectoryKey) {
        order.removeAll { $0 == key }; order.append(key)
    }

    private func insert(_ value: DirectoryPresentation) {
        guard maximumViews > 0, value.rowIDs.count <= maximumRowIDs else { return }
        if let old = entries.removeValue(forKey: value.key) { retainedRowIDs -= old.rowIDs.count }
        touch(value.key)
        entries[value.key] = value
        retainedRowIDs += value.rowIDs.count
        while entries.count > maximumViews || retainedRowIDs > maximumRowIDs {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { retainedRowIDs -= removed.rowIDs.count }
        }
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

    static func prepare(_ snapshot: DiskSnapshot, restoration: ScanRestoration = ScanRestoration(), metric: SizeMetric, sort: DirectorySort) throws -> PreparedScan {
        let wanted = Set(restoration.history + restoration.future + restoration.queue + [restoration.currentPath, restoration.selectedPath].compactMap { $0 })
        var restored: [String: Int] = [:]
        if !wanted.isEmpty {
            for node in snapshot.nodes {
                let path = node.url.path
                if wanted.contains(path) { restored[path] = node.id }
                if restored.count == wanted.count { break }
            }
        }
        let current = restoration.currentPath.flatMap { restored[$0] } ?? 0
        // Stopping a scan intentionally keeps its partial result, even in a cancelled worker.
        let presentation = try DirectoryPresentation.prepare(snapshot, directoryID: current, metric: metric, sort: sort, cancelled: { false })
        return PreparedScan(snapshot: snapshot, presentation: presentation,
                            selectedID: restoration.selectedPath.flatMap { restored[$0] },
                            history: restoration.history.compactMap { restored[$0] }, future: restoration.future.compactMap { restored[$0] },
                            queue: Set(restoration.queue.compactMap { restored[$0] }.filter { CleanupPolicy.reason(for: $0, in: snapshot) == nil }))
    }
}
