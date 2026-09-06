import Foundation
import SQLite3
#if SWIFT_PACKAGE
@testable import HaoDiskCore
#endif

// Materialization is confined to small correctness fixtures; the app uses paged queries.
extension DiskSnapshot {
    var nodes: [DiskNode] {
        var values: [DiskNode] = []
        _ = try! index.access { try index.rows("SELECT * FROM nodes ORDER BY id") { values.append(ScanIndex.decode($0)) } }
        return values
    }
    func children(of id: Int, metric: SizeMetric, sort: DirectorySort = .sizeDescending) -> [DiskNode] {
        let view = try! DirectoryPresentation.prepare(self, directoryID: id, metric: metric, sort: sort, cancelled: { false })
        return view.rowIDs.compactMap { view.nodes[$0] }
    }
    init(nodes: [DiskNode], issues: [ScanIssue], issueCount: Int, stopReason: ScanStopReason?, elapsed: TimeInterval, totalCapacity: Int64?, availableCapacity: Int64?) {
        let index = try! ScanIndex()
        try! index.transaction {
            for node in nodes {
                try index.insert(node, ownLogical: node.isDirectory ? 0 : node.logicalBytes, ownAllocated: node.isDirectory ? 0 : node.allocatedBytes, insidePackage: node.isPackage, protected: node.isPackage || CleanupPolicy.protectedPath(node.url))
            }
            try index.execute("UPDATE nodes SET enumerated=1")
            if stopReason != nil { try index.execute("UPDATE nodes SET enumerated=0,state=1 WHERE id=0") }
            try index.aggregateAll(lastID: nodes.last?.id ?? 0)
        }
        self.init(index: index, root: try! index.node(0)!, issues: issues, stopReason: stopReason, elapsed: elapsed, totalCapacity: totalCapacity, availableCapacity: availableCapacity)
    }
}
extension CleanupPolicy {
    static func reason(for id: Int, in snapshot: DiskSnapshot) -> String? { try! snapshot.index.node(id)?.restriction?.message }
    static func adding(_ id: Int, to selection: Set<Int>, in snapshot: DiskSnapshot) -> Set<Int> {
        let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        return adding(nodes[id]!, to: selection, nodes: nodes)
    }
}
extension CleanupResult {
    var first: TrashOutcome? { outcomes.first }
    func first(where test: (TrashOutcome) -> Bool) -> TrashOutcome? { outcomes.first(where: test) }
    func allSatisfy(_ test: (TrashOutcome) -> Bool) -> Bool { outcomes.allSatisfy(test) }
}
