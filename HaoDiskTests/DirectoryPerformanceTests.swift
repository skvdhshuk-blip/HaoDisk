import XCTest
import Darwin
#if SWIFT_PACKAGE
@testable import HaoDiskCore
#else
import Combine
#endif

final class DirectoryPerformanceTests: XCTestCase {
    private func snapshot(_ count: Int = 100, folders: Int = 3) -> DiskSnapshot {
        let root = URL(fileURLWithPath: "/HaoDisk-Performance")
        let directory = FileIdentity(device: 1, inode: 1, mode: UInt16(S_IFDIR | 0o755), size: 0, modifiedSeconds: 0, modifiedNanos: 0)
        let file = FileIdentity(device: 1, inode: 2, mode: UInt16(S_IFREG | 0o644), size: 0, modifiedSeconds: 0, modifiedNanos: 0)
        var nodes = [DiskNode(id: 0, url: root, parent: nil, identity: directory, isPackage: false)]
        for i in 1...folders {
            nodes.append(DiskNode(id: i, url: root.appendingPathComponent("Folder\(i)"), parent: 0, identity: directory, isPackage: false))
            nodes[0].children.append(i)
        }
        for i in 0..<count {
            let parent = i % folders + 1
            let id = nodes.count
            var node = DiskNode(id: id, url: nodes[parent].url.appendingPathComponent("中文长名称-\(count-i)"), parent: parent, identity: file, isPackage: false)
            node.allocatedBytes = Int64(i + 1) * 4096
            node.logicalBytes = Int64(count - i)
            nodes.append(node)
            nodes[parent].children.append(id)
            nodes[parent].allocatedBytes += node.allocatedBytes
            nodes[parent].logicalBytes += node.logicalBytes
        }
        nodes[0].allocatedBytes = nodes[1...folders].reduce(0) { $0 + $1.allocatedBytes }
        nodes[0].logicalBytes = nodes[1...folders].reduce(0) { $0 + $1.logicalBytes }
        return DiskSnapshot(nodes: nodes, issues: [], issueCount: 0, stopReason: nil, elapsed: 0, totalCapacity: nil, availableCapacity: nil)
    }

    func testPresentationMatchesSortingAndIndexForBothMetrics() throws {
        let scan = snapshot()
        for metric in SizeMetric.allCases {
            for sort in DirectorySort.allCases {
                let view = try DirectoryPresentation.prepare(scan, directoryID: 1, metric: metric, sort: sort)
                XCTAssertEqual(view.rowIDs, scan.children(of: 1, metric: metric, sort: sort).map(\.id))
                for (row, id) in view.rowIDs.enumerated() { XCTAssertEqual(view.rowByID[id], row) }
                XCTAssertEqual(view.map.entries.reduce(0) { $0 + $1.bytes }, scan.nodes[1].bytes(metric))
            }
        }
    }

    func testCacheHitsAndLeastRecentlyUsedEviction() async throws {
        let scan = snapshot(90)
        let cache = DirectoryCache(maximumViews: 2)
        for id in [1, 2, 1, 3, 1] { _ = try await cache.value(for: scan, directoryID: id, metric: .allocated, sort: .sizeDescending) }
        let preparations = await cache.preparationCount
        let entries = await cache.entryCount
        XCTAssertEqual(preparations, 3)
        XCTAssertEqual(entries, 2)
        _ = try await cache.value(for: scan, directoryID: 2, metric: .allocated, sort: .sizeDescending)
        let afterEviction = await cache.preparationCount
        XCTAssertEqual(afterEviction, 4)
    }

    func testCacheBudgetMetricSortVersionAndReset() async throws {
        let scan = snapshot(90)
        let cache = DirectoryCache(maximumViews: 16, maximumRowIDs: 60)
        for id in [1, 2, 3] { _ = try await cache.value(for: scan, directoryID: id, metric: .allocated, sort: .sizeDescending) }
        let rows = await cache.retainedRowIDs
        let entries = await cache.entryCount
        XCTAssertEqual(rows, 60)
        XCTAssertEqual(entries, 2)
        let logical = try await cache.value(for: scan, directoryID: 3, metric: .logical, sort: .sizeDescending)
        let named = try await cache.value(for: scan, directoryID: 3, metric: .logical, sort: .nameAscending)
        XCTAssertNotEqual(logical.key, named.key)
        let fresh = snapshot(12)
        let replaced = try await cache.value(for: fresh, directoryID: 3, metric: .logical, sort: .nameAscending)
        XCTAssertNotEqual(replaced.key.version, named.key.version)
        XCTAssertEqual(replaced.rowIDs.count, 4)
        let replacedEntries = await cache.entryCount
        XCTAssertEqual(replacedEntries, 1)
        await cache.reset()
        let emptyRows = await cache.retainedRowIDs
        let emptyEntries = await cache.entryCount
        XCTAssertEqual(emptyRows, 0)
        XCTAssertEqual(emptyEntries, 0)
        let tiny = DirectoryCache(maximumRowIDs: 2)
        _ = try await tiny.value(for: scan, directoryID: 1, metric: .allocated, sort: .sizeDescending)
        let oversized = await tiny.entryCount
        XCTAssertEqual(oversized, 0)
    }

    func testLargeDirectoryCancellationAndDefaultCacheLimits() async throws {
        let scan = snapshot(100_000, folders: 1)
        var checks = 0
        XCTAssertThrowsError(try DirectoryPresentation.prepare(scan, directoryID: 1, metric: .logical, sort: .nameAscending, cancelled: { checks += 1; return checks > 100 })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let cache = DirectoryCache()
        for metric in SizeMetric.allCases {
            for sort in DirectorySort.allCases {
                let view = try await cache.value(for: scan, directoryID: 1, metric: metric, sort: sort)
                XCTAssertEqual(view.rowIDs.count, 100_000)
                XCTAssertEqual(view.map.entries.count, 81)
                let retained = await cache.retainedRowIDs
                XCTAssertLessThanOrEqual(retained, 500_000)
            }
        }
        let entries = await cache.entryCount
        XCTAssertEqual(entries, 5)
        let small = snapshot(40, folders: 20)
        for id in 1...20 { _ = try await cache.value(for: small, directoryID: id, metric: .allocated, sort: .sizeDescending) }
        let viewLimit = await cache.entryCount
        XCTAssertEqual(viewLimit, 16)
        let cancelled = Task { () throws -> DirectoryPresentation in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.value(for: small, directoryID: 20, metric: .logical, sort: .nameAscending)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled request returned data") } catch { XCTAssertTrue(error is CancellationError) }
        let unchanged = await cache.entryCount
        XCTAssertEqual(unchanged, 16)
    }

    func testRestorationUsesPathsAfterIDsChangeAndKeepsPartialResults() throws {
        let old = snapshot(20, folders: 2)
        let new = snapshot(21, folders: 3)
        let selectedPath = old.nodes[6].url.path
        let result = try PreparedScan.prepare(new, restoration: ScanRestoration(currentPath: old.nodes[2].url.path, selectedPath: selectedPath, history: [old.root.url.path], future: ["/gone"], queue: [old.nodes[1].url.path]), metric: .logical, sort: .nameAscending)
        XCTAssertEqual(result.presentation.key.directoryID, 2)
        XCTAssertEqual(result.selectedID.map { new.nodes[$0].url.path }, selectedPath)
        XCTAssertEqual(result.history, [0])
        XCTAssertTrue(result.future.isEmpty)
        XCTAssertEqual(result.queue, [1])
        let stopped = DiskSnapshot(nodes: old.nodes, issues: [], issueCount: 0, stopReason: .cancelled, elapsed: 1, totalCapacity: nil, availableCapacity: nil)
        let partial = try PreparedScan.prepare(stopped, metric: .allocated, sort: .sizeDescending)
        XCTAssertEqual(partial.snapshot.stopReason, .cancelled)
        XCTAssertEqual(partial.presentation.rowIDs.count, 2)
    }

    #if !SWIFT_PACKAGE
    @MainActor func testRapidNavigationMetricChangesAndOldResultsCannotReplaceNewScan() async throws {
        let model = DiskModel()
        let old = snapshot(12_000)
        await model.install(try PreparedScan.prepare(old, metric: .allocated, sort: .sizeDescending))
        model.navigate(1)
        model.navigate(2)
        model.back()
        model.forward()
        model.metric = .logical
        model.sort = .nameDescending
        await model.waitForDirectory()
        XCTAssertEqual(model.currentID, 2)
        XCTAssertEqual(model.presentation?.key.metric, .logical)
        XCTAssertEqual(model.presentation?.key.sort, .nameDescending)
        model.navigate(3)
        let new = snapshot(9)
        await model.install(try PreparedScan.prepare(new, metric: .logical, sort: .nameDescending))
        await model.waitForDirectory()
        XCTAssertEqual(model.snapshot?.version, new.version)
        XCTAssertEqual(model.currentID, 0)
        model.navigate(2)
        model.forgetFolder()
        await model.waitForDirectory()
        XCTAssertNil(model.display)
    }

    @MainActor func testOldTilesCannotReadOrActOnReusedIDsAfterCleanupRescan() async throws {
        let model = DiskModel()
        let old = snapshot(90)
        await model.install(try PreparedScan.prepare(old, metric: .allocated, sort: .sizeDescending))
        XCTAssertTrue(model.select(90, version: old.version))
        let fresh = snapshot(3)
        await model.install(try PreparedScan.prepare(fresh, metric: .allocated, sort: .sizeDescending))
        XCTAssertNil(model.node(for: 90, version: old.version))
        XCTAssertNil(model.node(for: 1, version: old.version))
        XCTAssertFalse(model.select(90, version: old.version))
        XCTAssertFalse(model.select(1, version: old.version))
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.select(1, version: fresh.version))
        XCTAssertEqual(model.selectedID, 1)
        model.forgetFolder()
        XCTAssertNil(model.node(for: 1, version: fresh.version))
    }

    @MainActor func testProgressDoesNotPublishBrowserChangesAndLayoutIgnoresSelection() async throws {
        let model = DiskModel()
        let scan = snapshot(12_000, folders: 1)
        await model.install(try PreparedScan.prepare(scan, metric: .allocated, sort: .sizeDescending))
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        for i in 0..<100 { model.scanProgress.update(ScanProgress(count: i, bytes: Int64(i), folder: "folder")) }
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(subscription) {}
        let map = try DirectoryPresentation.prepare(scan, directoryID: 1, metric: .allocated, sort: .sizeDescending).map
        let layout = MapLayoutModel()
        let size = CGSize(width: 700, height: 500)
        layout.update(map, size: size)
        for id in scan.nodes[1].children.prefix(100) {
            model.selectedID = id
            _ = model.selectedCleanupReason
            layout.update(map, size: size)
        }
        XCTAssertEqual(layout.layoutCount, 1)
        XCTAssertEqual(layout.measurementCount, 1)
        for n in 0..<100 { layout.update(map, size: CGSize(width: 701+n, height: 500)) }
        XCTAssertEqual(layout.layoutCount, 101)
        XCTAssertEqual(layout.measurementCount, 1)
        XCTAssertTrue(layout.tiles.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
    }
    #endif
}
