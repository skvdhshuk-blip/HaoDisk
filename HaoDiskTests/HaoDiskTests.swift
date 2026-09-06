import XCTest
import CoreGraphics
#if SWIFT_PACKAGE
@testable import HaoDiskCore
#endif

final class HaoDiskTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: url)
        return url
    }

    func testNestedHiddenAndEmptyFiles() throws {
        try file("folder/a", bytes: 1234)
        try file("folder/.hidden", bytes: 567)
        try file("empty", bytes: 0)
        let scan = try DiskScanner().scan(root)
        XCTAssertEqual(scan.root.logicalBytes, 1801)
        XCTAssertEqual(scan.root.descendantCount, 4)
        XCTAssertTrue(scan.isComplete)
        let folder = try XCTUnwrap(scan.nodes.first { $0.name == "folder" })
        XCTAssertEqual(folder.logicalBytes, 1801)
        XCTAssertEqual(folder.childCount, 2)
    }

    func testAppleDoubleAndDotFilesAreIncluded() throws {
        try file("._metadata", bytes: 233)
        try file(".hidden", bytes: 100)
        try file("visible", bytes: 200)
        let scan = try DiskScanner().scan(root)
        XCTAssertEqual(scan.root.descendantCount, 3)
        XCTAssertEqual(scan.root.logicalBytes, 533)
    }

    func testSymbolicLinkNeverTraversesTargetAndHardLinksCountOnce() throws {
        let original = try file("data", bytes: 8192)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let scan = try DiskScanner().scan(root)
        XCTAssertEqual(scan.nodes.count, 4)
        XCTAssertEqual(scan.nodes.filter(\.isHardLinkDuplicate).count, 1)
        let regularBytes = scan.nodes.filter { $0.identity.isRegular }.reduce(0) { $0 + $1.logicalBytes }
        XCTAssertEqual(regularBytes, 8192)
        let link = try XCTUnwrap(scan.nodes.first { $0.name == "loop" })
        XCTAssertTrue(link.childCount == 0)
        XCTAssertNotNil(CleanupPolicy.reason(for: link.id, in: scan))
    }

    func testSparseFileSeparatesLogicalAndAllocatedBytes() throws {
        let url = try file("sparse", bytes: 1)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()
        let scan = try DiskScanner().scan(root)
        XCTAssertEqual(scan.root.logicalBytes, 8 * 1024 * 1024)
        XCTAssertLessThan(scan.root.allocatedBytes, scan.root.logicalBytes)
    }

    func testCancellationNeverReportsAnEmptyDirectoryAsComplete() throws {
        for n in 0..<10 { try file("folder/\(n)", bytes: 20) }
        let scan = try DiskScanner().scan(root, cancelled: { true })
        XCTAssertEqual(scan.stopReason, .cancelled)
        XCTAssertFalse(scan.isComplete)
        XCTAssertEqual(scan.root.state, .pending)
        XCTAssertEqual(nodeSizeLabel(scan.root, metric: .logical), "未扫描")
        XCTAssertNotNil(CleanupPolicy.reason(for: 0, in: scan))
    }

    func testPartialDirectoriesAreMarkedAndCannotEnterCleanup() throws {
        for n in 0..<10 { try file("folder/\(n)", bytes: 20) }
        let full = try DiskScanner().scan(root)
        let folder = try XCTUnwrap(full.nodes.first { $0.name == "folder" })
        try full.index.rows("UPDATE nodes SET state=1,enumerated=0 WHERE id=?", [.int(Int64(folder.id))])
        try full.index.aggregateAll(lastID: full.root.descendantCount)
        let partial = try XCTUnwrap(full.index.node(folder.id))
        XCTAssertEqual(partial.state, .partial)
        XCTAssertTrue(nodeSizeLabel(partial, metric: .logical).hasPrefix("已读"))
        XCTAssertEqual(partial.restriction, .unreadable)
        XCTAssertEqual(try full.index.node(0)?.state, .partial)
    }

    func testTreemapPreservesProportionBoundsAndDoesNotOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 530)
        let weights = (1...125).map { MapWeight(id: $0, value: Double($0 * $0)) }
        let tiles = Treemap.layout(weights, in: bounds)
        let sum = weights.reduce(0) { $0 + $1.value }
        XCTAssertEqual(tiles.count, weights.count)
        for (index, tile) in tiles.enumerated() {
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect))
            XCTAssertEqual(tile.rect.width * tile.rect.height / (bounds.width * bounds.height), Double(tile.id * tile.id) / sum, accuracy: 0.000001)
            for other in tiles.dropFirst(index + 1) {
                let overlap = tile.rect.intersection(other.rect)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.0001)
            }
        }
    }

    func testTreemapRejectsZeroAndInvalidWeights() {
        XCTAssertTrue(Treemap.layout([MapWeight(id: 0, value: 0), MapWeight(id: 1, value: .nan)], in: CGRect(x: 0, y: 0, width: 20, height: 20)).isEmpty)
        XCTAssertTrue(Treemap.layout([MapWeight(id: 0, value: 20)], in: .zero).isEmpty)
    }

    func testMapKeepsTinyItemsIndependentAtEveryWindowSize() throws {
        try file("large", bytes: 1_000_000)
        for n in 0..<20 { try file("small-\(n)", bytes: 1) }
        let scan = try DiskScanner().scan(root)
        let items = try DirectoryPresentation.prepare(scan, directoryID: 0, metric: .logical, sort: .sizeDescending).map
        XCTAssertEqual(items.entries.filter { $0.id != -1 }.count, 21)
        XCTAssertTrue(items.remainingFirstID == nil)
        for size in [CGSize(width: 380, height: 400), CGSize(width: 800, height: 700)] {
            let weights = items.weights
            let total = weights.reduce(0) { $0 + $1.value }
            let tiles = Treemap.layout(weights, in: CGRect(origin: .zero, size: size))
            XCTAssertEqual(Set(tiles.map(\.id)), Set(scan.children(of: 0, metric: .logical).map(\.id)))
            for tile in tiles {
                XCTAssertGreaterThan(tile.rect.width, 0)
                XCTAssertGreaterThan(tile.rect.height, 0)
                XCTAssertEqual(tile.rect.width * tile.rect.height / (size.width * size.height),
                               Double(scan.nodes[tile.id].logicalBytes) / total, accuracy: 0.000001)
            }
        }
    }

    func testMapLimitsOnlyPositiveItemsAndAccountsForOverflow() throws {
        for n in 0..<85 { try file("file-\(n)", bytes: n + 1) }
        try file("empty", bytes: 0)
        let scan = try DiskScanner().scan(root)
        let items = try DirectoryPresentation.prepare(scan, directoryID: 0, metric: .logical, sort: .sizeDescending).map
        XCTAssertEqual(items.entries.filter { $0.id != -1 }.count, 80)
        XCTAssertEqual(items.entries.last?.name, "其余 5 项")
        XCTAssertEqual(items.entries.last?.bytes, 15)
        XCTAssertEqual(items.weights.reduce(0) { $0 + $1.value }, Double(scan.root.logicalBytes))
        XCTAssertEqual(items.weights.last?.id, -1)
        XCTAssertFalse(items.entries.contains { $0.name == "empty" })
    }

    func testMapFollowsSelectedSizeMetric() throws {
        let sparse = try file("sparse", bytes: 1)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()
        try file("regular", bytes: 16384)
        let scan = try DiskScanner().scan(root)
        for metric in SizeMetric.allCases {
            let items = try DirectoryPresentation.prepare(scan, directoryID: 0, metric: metric, sort: .sizeDescending).map
            for weight in items.weights {
                XCTAssertEqual(weight.value, Double(scan.nodes[weight.id].bytes(metric)))
            }
        }
        XCTAssertEqual(try DirectoryPresentation.prepare(scan, directoryID: 0, metric: .logical, sort: .sizeDescending).map.entries.first?.name, "sparse")
        XCTAssertEqual(try DirectoryPresentation.prepare(scan, directoryID: 0, metric: .allocated, sort: .sizeDescending).map.entries.first?.name, "regular")
    }

    func testVolumeCapacityIsIndependentOfDirectoryScanAndMissingIsUnknown() throws {
        let capacity = VolumeCapacity.read(at: root)
        let expected = try root.resourceValues(forKeys: [.volumeTotalCapacityKey])
        XCTAssertEqual(capacity.total, expected.volumeTotalCapacity.map(Int64.init))
        XCTAssertGreaterThan(try XCTUnwrap(capacity.total), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(capacity.available), 0)
        let empty = try DiskScanner().scan(root)
        XCTAssertEqual(empty.root.logicalBytes, 0)
        XCTAssertEqual(empty.totalCapacity, capacity.total)
        XCTAssertEqual(VolumeCapacity.read(at: root.appendingPathComponent("missing")), VolumeCapacity(total: nil, available: nil))
        XCTAssertNotEqual(VolumeCapacity(total: nil, available: nil), VolumeCapacity(total: 0, available: 0))
    }

    func testPathBoundaryAndProtectedDirectories() {
        XCTAssertFalse(CleanupPolicy.isDescendant(URL(fileURLWithPath: "/Users/a-backup/file"), of: URL(fileURLWithPath: "/Users/a")))
        XCTAssertFalse(CleanupPolicy.isDescendant(URL(fileURLWithPath: "/Users/a"), of: URL(fileURLWithPath: "/Users/a")))
        XCTAssertTrue(CleanupPolicy.isDescendant(URL(fileURLWithPath: "/Users/a/file"), of: URL(fileURLWithPath: "/Users/a")))
        XCTAssertTrue(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Users/a/Library/Caches")))
        XCTAssertTrue(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/System/Library")))
        XCTAssertTrue(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Users/a/library/Caches")))
        XCTAssertTrue(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Volumes/External/System/a")))
        XCTAssertFalse(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Users/a/Downloads/file")))
    }

    func testBasketEliminatesParentChildOverlap() throws {
        try file("folder/a", bytes: 50)
        let scan = try DiskScanner().scan(root)
        let folder = try XCTUnwrap(scan.nodes.first { $0.name == "folder" })
        let child = try XCTUnwrap(scan.nodes.first { $0.name == "a" })
        XCTAssertNotNil(CleanupPolicy.reason(for: 0, in: scan))
        XCTAssertEqual(CleanupPolicy.adding(folder.id, to: [child.id], in: scan), [folder.id])
        XCTAssertEqual(CleanupPolicy.adding(child.id, to: [folder.id], in: scan), [folder.id])
    }

    func testTrashRefusesProtectedLocationWithoutCallingOperation() throws {
        try file(".Trash/a", bytes: 50)
        let scan = try DiskScanner().scan(root)
        var called = false
        let result = TrashService().move([0, 1], in: scan) { _ in called = true }
        XCTAssertFalse(called)
        XCTAssertTrue(result.allSatisfy { $0.error != nil })
    }

    func testTrashChecksChangedFilesAndReportsPartialFailures() throws {
        let changed = try file("changed", bytes: 50)
        try file("okay", bytes: 60)
        let scan = try DiskScanner().scan(root)
        try Data(repeating: 66, count: 75).write(to: changed)
        var called: [String] = []
        let result = TrashService().move(Set(scan.children(of: 0, metric: .logical).map(\.id)), in: scan) { called.append($0.lastPathComponent) }
        XCTAssertEqual(called, ["okay"])
        XCTAssertNil(result.first { $0.name == "okay" }?.error)
        XCTAssertNotNil(result.first { $0.name == "changed" }?.error)
    }

    func testTrashRejectsReplacedParentAndNeverDeletesPermanently() throws {
        try file("folder/a", bytes: 50)
        let scan = try DiskScanner().scan(root)
        let child = try XCTUnwrap(scan.nodes.first { $0.name == "a" })
        try FileManager.default.moveItem(at: root.appendingPathComponent("folder"), to: root.appendingPathComponent("old"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("folder"), withDestinationURL: root.appendingPathComponent("old"))
        var called = false
        let result = TrashService().move([child.id], in: scan) { _ in called = true }
        XCTAssertFalse(called)
        XCTAssertNotNil(result.first?.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("old/a").path))
    }

    func testChangedNestedContentStopsDirectoryCleanup() throws {
        let url = try file("folder/nested/a", bytes: 50)
        let scan = try DiskScanner().scan(root)
        let folder = try XCTUnwrap(scan.nodes.first { $0.name == "folder" })
        try Data(repeating: 67, count: 70).write(to: url)
        var called = false
        let result = TrashService().move([folder.id], in: scan) { _ in called = true }
        XCTAssertFalse(called)
        XCTAssertNotNil(result.first?.error)
    }

    func testValidDirectoryReachesTrashAndFailureIsPreserved() throws {
        try file("folder/nested/a", bytes: 50)
        let scan = try DiskScanner().scan(root)
        let folder = try XCTUnwrap(scan.nodes.first { $0.name == "folder" })
        var called = false
        let result = TrashService().move([folder.id], in: scan) { _ in
            called = true
            throw CleanupError.refused("Volume does not support Trash")
        }
        XCTAssertTrue(called)
        XCTAssertEqual(result.first?.error, "Volume does not support Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder/nested/a").path))
    }

    func testProjectLibraryAndItsParentCanBeCleaned() throws {
        try file("folder/Library/a", bytes: 50)
        let scan = try DiskScanner().scan(root)
        let folder = try XCTUnwrap(scan.nodes.first { $0.name == "folder" })
        XCTAssertNil(CleanupPolicy.reason(for: folder.id, in: scan))
        let library = try XCTUnwrap(scan.nodes.first { $0.name == "Library" })
        XCTAssertNil(CleanupPolicy.reason(for: library.id, in: scan))
        XCTAssertFalse(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Users/a/project/library/data")))
        XCTAssertFalse(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Volumes/External/project/Library/data")))
        XCTAssertTrue(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Volumes/External/Users/a/Library/data")))
        XCTAssertTrue(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Library/data")))
    }

    func testPackagesProtectContentsButNotTheirParent() throws {
        try file("outer/Test.app/Contents/data", bytes: 10)
        try file("okay/item", bytes: 10)
        let scan = try DiskScanner().scan(root)
        for name in ["Test.app", "Contents", "data"] {
            let node = try XCTUnwrap(scan.nodes.first { $0.name == name })
            XCTAssertNotNil(CleanupPolicy.reason(for: node.id, in: scan))
        }
        let outer = try XCTUnwrap(scan.nodes.first { $0.name == "outer" })
        XCTAssertNil(CleanupPolicy.reason(for: outer.id, in: scan))
        let okay = try XCTUnwrap(scan.nodes.first { $0.name == "okay" })
        XCTAssertNil(CleanupPolicy.reason(for: okay.id, in: scan))
        XCTAssertTrue(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Users/a/Downloads/../Library/data")))
        XCTAssertFalse(CleanupPolicy.protectedPath(URL(fileURLWithPath: "/Users/a/Library/../Downloads/data")))
    }

    func testProtectedTrashStillBlocksParentWithAnApp() throws {
        try file("outer/Test.app/Contents/data", bytes: 10)
        try file("outer/.Trash/data", bytes: 10)
        let scan = try DiskScanner().scan(root)
        let outer = try XCTUnwrap(scan.nodes.first { $0.name == "outer" })
        XCTAssertEqual(outer.restriction, .protectedContent)
    }

    func testPermissionFailureIsVisibleAndBlocksCleanup() throws {
        try file("blocked/a", bytes: 50)
        let directory = root.appendingPathComponent("blocked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let scan = try DiskScanner().scan(root)
        XCTAssertFalse(scan.isComplete)
        XCTAssertGreaterThan(scan.issueCount, 0)
        let blocked = try XCTUnwrap(scan.nodes.first { $0.name == "blocked" })
        XCTAssertGreaterThan(blocked.issueCount, 0)
        XCTAssertNotNil(CleanupPolicy.reason(for: blocked.id, in: scan))
    }

    func testAllDirectorySortOrders() throws {
        try file("file2", bytes: 100)
        try file("file10", bytes: 200)
        try file("Alpha", bytes: 1000)
        let scan = try DiskScanner().scan(root)
        XCTAssertEqual(scan.children(of: 0, metric: .logical, sort: .sizeDescending).map(\.name), ["Alpha", "file10", "file2"])
        XCTAssertEqual(scan.children(of: 0, metric: .logical, sort: .sizeAscending).map(\.name), ["file2", "file10", "Alpha"])
        XCTAssertEqual(scan.children(of: 0, metric: .logical, sort: .nameAscending).map(\.name), ["Alpha", "file2", "file10"])
        XCTAssertEqual(scan.children(of: 0, metric: .logical, sort: .nameDescending).map(\.name), ["file10", "file2", "Alpha"])
    }

    #if !SWIFT_PACKAGE
    @MainActor func testVolumeStateSurvivesMetricChangesAndClearsWithAuthorization() {
        let model = DiskModel()
        let capacity = VolumeCapacity(total: 1000, available: 400)
        model.volumeCapacity = capacity
        model.metric = .logical
        XCTAssertEqual(model.volumeCapacity, capacity)
        model.metric = .allocated
        XCTAssertEqual(model.volumeCapacity, capacity)
        model.forgetFolder()
        XCTAssertNil(model.volumeCapacity)
    }

    @MainActor func testNavigationSelectionSortAndCleanupReview() async throws {
        try file("folder/a", bytes: 50)
        try file("z-file", bytes: 20)
        let scan = try DiskScanner().scan(root)
        let model = DiskModel()
        model.metric = .logical
        await model.install(try PreparedScan.prepare(scan, metric: .logical, sort: .sizeDescending))
        model.selectOffset(1)
        XCTAssertEqual(model.selected?.name, "folder")
        model.openSelected()
        await model.waitForDirectory()
        XCTAssertEqual(model.current?.name, "folder")
        XCTAssertTrue(model.canGoBack)
        model.selectOffset(1)
        XCTAssertEqual(model.selected?.name, "a")
        model.reviewSelected()
        XCTAssertTrue(model.showReview)
        XCTAssertEqual(model.basketNodes.map(\.name), ["a"])
        model.showReview = false
        model.back()
        await model.waitForDirectory()
        XCTAssertEqual(model.currentID, 0)
        model.forward()
        await model.waitForDirectory()
        XCTAssertEqual(model.current?.name, "folder")
        model.up()
        model.sort = .nameDescending
        await model.waitForDirectory()
        XCTAssertEqual(model.presentation?.rowIDs.map { scan.nodes[$0].name }, ["z-file", "folder"])
        model.isScanning = true
        model.selectOffset(1)
        XCTAssertNil(model.selectedID)
    }
    #endif
}
