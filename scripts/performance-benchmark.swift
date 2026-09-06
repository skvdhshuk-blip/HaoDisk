// swiftc -O HaoDisk/Core/*.swift HaoDisk/UI/DiskModel.swift HaoDisk/UI/MapLayout.swift scripts/performance-benchmark.swift -o /tmp/haodisk-benchmark
import Foundation
import AppKit

@main struct Benchmark {
    static func duration<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
        let start = ProcessInfo.processInfo.systemUptime
        let value = try operation()
        return (value, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    static func percentile(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))] }
    static func synthetic(_ count: Int) throws -> DiskSnapshot {
        let index = try ScanIndex()
        let root = URL(fileURLWithPath: "/HaoDisk-Benchmark")
        let identity = FileIdentity(device: 1, inode: 0, mode: 0o40755, size: 0, modifiedSeconds: 0, modifiedNanos: 0)
        try index.transaction {
            try index.insert(DiskNode(id: 0, url: root, parent: nil, identity: identity, isPackage: false), ownLogical: 0, ownAllocated: 0, insidePackage: false, protected: false)
            for i in 1...count {
                try autoreleasepool {
                    let identity = FileIdentity(device: 1, inode: UInt64(i), mode: 0o100644, size: Int64(i), modifiedSeconds: 0, modifiedNanos: 0)
                    let node = DiskNode(id: i, url: root.appendingPathComponent("document-\((i * 7919) % count)-长中文名称.txt"), parent: 0, identity: identity, isPackage: false)
                    try index.insert(node, ownLogical: Int64(i), ownAllocated: Int64(i % 127 + 1) * 4096, insidePackage: false, protected: false)
                }
            }
            try index.execute("UPDATE nodes SET enumerated=1")
            try index.aggregateAll(lastID: count)
        }
        return DiskSnapshot(index: index, root: try index.node(0)!, issues: [], stopReason: nil, elapsed: 0, totalCapacity: nil, availableCapacity: nil)
    }
    @MainActor static func main() async throws {
        var report: [String: Any] = ["version": "0.2.4", "measurement": "internal logic milliseconds; not input-to-frame latency"]
        for count in [12_000, 100_000, 600_001] {
            let scan = try await Task.detached { try synthetic(count) }.value
            let prepared = try await Task.detached { try duration { try PreparedScan.prepare(scan, metric: .logical, sort: .nameAscending) } }.value
            let model = DiskModel()
            await model.install(prepared.0)
            var selections: [Double] = [], cached: [Double] = [], paging: [Double] = []
            let queries = scan.index.queryCount
            for id in model.presentation!.rowIDs.prefix(100) {
                selections.append(duration { _ = model.select(id, version: scan.version); _ = model.selectedCleanupReason }.1)
            }
            let selectionQueries = scan.index.queryCount - queries
            for _ in 0..<100 {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try await model.directoryCache.value(for: scan, directoryID: 0, metric: .logical, sort: .nameAscending)
                cached.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            }
            for row in stride(from: 0, to: min(count, 100_000), by: 4096) {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try await model.directoryCache.value(for: scan, directoryID: 0, metric: .logical, sort: .nameAscending, row: row)
                paging.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            }
            let layout = MapLayoutModel()
            let map = model.presentation!.map
            layout.update(map, size: CGSize(width: 700, height: 500))
            let hoverReuse = duration { for _ in 0..<1000 { layout.update(map, size: CGSize(width: 700, height: 500)) } }.1
            report["synthetic_\(count)"] = ["prepare_ms": prepared.1, "selection_p95_ms": percentile(selections), "selection_sql_queries": selectionQueries,
                "cache_p95_ms": percentile(cached), "page_p95_ms": percentile(paging), "retained_rows": await model.directoryCache.retainedRowIDs,
                "layout_reuse_1000_ms": hoverReuse, "layout_count": layout.layoutCount, "node_count": scan.root.descendantCount, "logical_total": scan.root.logicalBytes]
            model.forgetFolder()
        }
        for path in CommandLine.arguments.dropFirst() {
            let scan = try await Task.detached {
                try DiskScanner().scan(URL(fileURLWithPath: path), progress: { value in
                    if value.count % 10_000 < 100 { FileHandle.standardError.write(Data("\(value.count) \(value.folder)\n".utf8)) }
                })
            }.value
            let prepared = try await Task.detached { try duration { try PreparedScan.prepare(scan, metric: .allocated, sort: .sizeDescending) } }.value
            var children: [[String: Any]] = []
            for row in prepared.0.presentation.pages.values.flatMap({ $0.values }).sorted(by: { $0.name < $1.name }) {
                children.append(["name": row.name, "logical": row.logicalBytes, "allocated": row.allocatedBytes, "descendants": row.descendantCount, "state": row.state.rawValue])
            }
            report[path] = ["scan_seconds": scan.elapsed, "nodes": scan.root.descendantCount, "logical": scan.root.logicalBytes, "allocated": scan.root.allocatedBytes,
                            "complete": scan.isComplete, "issues": scan.issueCount, "prepare_ms": prepared.1, "children": children]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
