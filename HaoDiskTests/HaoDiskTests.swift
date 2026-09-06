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
        XCTAssertEqual(folder.children.count, 2)
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
        XCTAssertTrue(link.children.isEmpty)
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

    func testCancellationAndLimitAreNeverComplete() throws {
        for n in 0..<10 { try file("\(n)", bytes: 20) }
        let cancelled = try DiskScanner().scan(root, cancelled: { true })
        XCTAssertTrue(cancelled.stoppedEarly)
        XCTAssertFalse(cancelled.isComplete)
        let limited = try DiskScanner(maximumNodes: 4).scan(root)
        XCTAssertEqual(limited.nodes.count, 4)
        XCTAssertTrue(limited.stoppedEarly)
        XCTAssertGreaterThan(limited.issueCount, 0)
        XCTAssertNotNil(CleanupPolicy.reason(for: 1, in: limited))
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
        try file("Library/a", bytes: 50)
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
        let result = TrashService().move(Set(scan.root.children), in: scan) { called.append($0.lastPathComponent) }
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

    func testLibraryIsProtectedEvenThroughItsParent() throws {
        try file("folder/Library/a", bytes: 50)
        let scan = try DiskScanner().scan(root)
        let folder = try XCTUnwrap(scan.nodes.first { $0.name == "folder" })
        XCTAssertNotNil(CleanupPolicy.reason(for: folder.id, in: scan))
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
}
