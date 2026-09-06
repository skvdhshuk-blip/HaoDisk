import XCTest
#if SWIFT_PACKAGE
@testable import HaoDiskCore
#endif

final class IncrementalIndexTests: XCTestCase {
    var root: URL!
    var moved: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".fixtures-IndexTests-\(UUID().uuidString)")
        moved = root.appendingPathComponent("../HaoDisk-Moved-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        try FileManager.default.removeItem(at: moved)
    }
    @discardableResult func file(_ path: String, _ size: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: size).write(to: url)
        return url
    }
    func move(_ url: URL) throws { try FileManager.default.moveItem(at: url, to: moved.appendingPathComponent(UUID().uuidString)) }
    func testProjectWithLibraryAndAppCanBeMovedAndUpdatedIncrementally() throws {
        try file("project/library/data", 100)
        try file("project/build/Test.app/Contents/Library/data", 200)
        try file("other/keep", 300)
        let scan = try DiskScanner().scan(root)
        let project = try XCTUnwrap(scan.index.node(path: root.appendingPathComponent("project").path))
        let library = try XCTUnwrap(scan.index.node(path: root.appendingPathComponent("project/library").path))
        let app = try XCTUnwrap(scan.index.node(path: root.appendingPathComponent("project/build/Test.app").path))
        XCTAssertNil(project.restriction)
        XCTAssertNil(library.restriction)
        XCTAssertEqual(app.restriction, .package)
        let childResult = TrashService().move([library.id], in: scan, operation: move)
        XCTAssertNil(childResult.first?.error)
        XCTAssertNil(childResult.updateError)
        XCTAssertNil(try scan.index.node(project.id)?.restriction)
        let result = TrashService().move([project.id], in: childResult.snapshot, operation: move)
        XCTAssertNil(result.first?.error)
        XCTAssertNil(result.updateError)
        XCTAssertEqual(result.snapshot.version, scan.version)
        XCTAssertNil(try scan.index.node(project.id))
        XCTAssertNil(try scan.index.node(app.id))
        XCTAssertEqual(result.snapshot.root.logicalBytes, 300)
    }

    func testChangedAppContentsStillBlockParentCleanup() throws {
        let data = try file("project/Test.app/Contents/data", 100)
        let scan = try DiskScanner().scan(root)
        let project = try XCTUnwrap(scan.index.node(path: root.appendingPathComponent("project").path))
        XCTAssertNil(project.restriction)
        try Data(repeating: 66, count: 200).write(to: data)
        var called = false
        let result = TrashService().move([project.id], in: scan) { _ in called = true }
        XCTAssertFalse(called)
        XCTAssertNotNil(result.first?.error)
        XCTAssertNotNil(try scan.index.node(project.id))
    }

    func testChildThenParentAndUnrelatedCacheSurvives() async throws {
        try file("folder/child", 100)
        try file("folder/keep", 200)
        try file("other/file", 300)
        let scan = try DiskScanner().scan(root)
        let folder = try XCTUnwrap(scan.index.node(path: root.appendingPathComponent("folder").path))
        let child = try XCTUnwrap(scan.index.node(path: root.appendingPathComponent("folder/child").path))
        let other = try XCTUnwrap(scan.index.node(path: root.appendingPathComponent("other").path))
        let cache = DirectoryCache()
        let before = try await cache.value(for: scan, directoryID: other.id, metric: .logical, sort: .sizeDescending)
        let result = TrashService().move([child.id], in: scan, operation: move)
        XCTAssertNil(result.updateError)
        XCTAssertNil(result.first?.error)
        XCTAssertEqual(result.snapshot.version, scan.version)
        XCTAssertNil(try scan.index.node(child.id))
        XCTAssertEqual(result.snapshot.root.logicalBytes, 500)
        XCTAssertEqual(try scan.index.node(folder.id)?.logicalBytes, 200)
        let after = try await cache.value(for: result.snapshot, directoryID: other.id, metric: .logical, sort: .sizeDescending)
        XCTAssertEqual(before.key, after.key)
        let preparations = await cache.preparationCount
        XCTAssertEqual(preparations, 1)
        let parentResult = TrashService().move([folder.id], in: result.snapshot, operation: move)
        XCTAssertNil(parentResult.first?.error)
        XCTAssertNil(parentResult.updateError)
        XCTAssertEqual(parentResult.snapshot.root.logicalBytes, 300)
        let restored = try PreparedScan.prepare(parentResult.snapshot, restoration: ScanRestoration(currentPath: folder.url.path, selectedPath: child.url.path), metric: .logical, sort: .sizeDescending)
        XCTAssertEqual(restored.presentation.key.directoryID, 0)
        XCTAssertNil(restored.selectedID)
    }
    func testDeletedHardLinkOwnerTransfersToRemainingAlias() throws {
        let source = try file("a/data", 4096)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: source, to: root.appendingPathComponent("b/alias"))
        let scan = try DiskScanner().scan(root)
        let owner = try XCTUnwrap(scan.nodes.first { $0.identity.isRegular && !$0.isHardLinkDuplicate })
        let alias = try XCTUnwrap(scan.nodes.first { $0.isHardLinkDuplicate })
        let result = TrashService().move([owner.id], in: scan, operation: move)
        XCTAssertNil(result.updateError)
        XCTAssertEqual(result.snapshot.root.logicalBytes, 4096)
        XCTAssertEqual(try scan.index.node(alias.id)?.logicalBytes, 4096)
        XCTAssertFalse(try XCTUnwrap(scan.index.node(alias.id)).isHardLinkDuplicate)
        let final = TrashService().move([alias.id], in: result.snapshot, operation: move)
        XCTAssertNil(final.updateError)
        XCTAssertEqual(final.snapshot.root.logicalBytes, 0)
    }
    func testMixedFailureKeepsFailedItemAndUpdatesSuccessfulItem() throws {
        let changed = try file("changed", 100)
        try file("okay", 200)
        let scan = try DiskScanner().scan(root)
        try Data(repeating: 1, count: 111).write(to: changed)
        let ids = Set(scan.nodes.filter { $0.parent == 0 }.map(\.id))
        let result = TrashService().move(ids, in: scan, operation: move)
        XCTAssertEqual(result.outcomes.filter { $0.error == nil }.count, 1)
        XCTAssertEqual(result.outcomes.filter { $0.error != nil }.count, 1)
        XCTAssertEqual(result.snapshot.root.logicalBytes, 100)
        XCTAssertNotNil(try scan.index.node(path: changed.path))
    }
    func testIndexWriteFailureAfterMoveNeverRepeatsMove() throws {
        try file("file", 100)
        let scan = try DiskScanner().scan(root)
        let id = try XCTUnwrap(scan.nodes.first { $0.parent == 0 }).id
        // A real SQLite write failure after the external operation has succeeded.
        try scan.index.execute("PRAGMA query_only=ON")
        var calls = 0
        let result = TrashService().move([id], in: scan) { try self.move($0); calls += 1 }
        XCTAssertNil(result.first?.error)
        XCTAssertNotNil(result.updateError)
        XCTAssertFalse(scan.index.usable)
        _ = TrashService().move([id], in: result.snapshot) { _ in calls += 1 }
        XCTAssertEqual(calls, 1)
    }
    func testDirectoryMutationBetweenChildAndParentCleanupIsRejected() throws {
        try file("folder/a", 100)
        try file("folder/b", 100)
        let scan = try DiskScanner().scan(root)
        let child = try XCTUnwrap(scan.index.node(path: root.appendingPathComponent("folder/a").path))
        let parent = try XCTUnwrap(scan.index.node(child.parent!))
        let result = TrashService().move([child.id], in: scan, operation: move)
        try file("folder/new", 100)
        let refused = TrashService().move([parent.id], in: result.snapshot, operation: move)
        XCTAssertNotNil(refused.first?.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.url.path))
    }
    func testPagesStayBoundedAndPreserveRowIdentity() async throws {
        let index = try ScanIndex()
        let dirIdentity = try FileIdentity.read(root).0
        try index.transaction {
            try index.insert(DiskNode(id: 0, url: root, parent: nil, identity: dirIdentity, isPackage: false), ownLogical: 0, ownAllocated: 0, insidePackage: false, protected: false)
            for i in 1...12_000 {
                let identity = FileIdentity(device: 1, inode: UInt64(i), mode: 0o100644, size: Int64(i), modifiedSeconds: 0, modifiedNanos: 0)
                try index.insert(DiskNode(id: i, url: root.appendingPathComponent("file\(i)"), parent: 0, identity: identity, isPackage: false), ownLogical: Int64(i), ownAllocated: 4096, insidePackage: false, protected: false)
            }
            try index.execute("UPDATE nodes SET enumerated=1")
            try index.aggregateAll(lastID: 12_000)
        }
        let scan = DiskSnapshot(index: index, root: try XCTUnwrap(index.node(0)), issues: [], stopReason: nil, elapsed: 0, totalCapacity: nil, availableCapacity: nil)
        let cache = DirectoryCache()
        for row in stride(from: 0, to: 12_000, by: 512) {
            let view = try await cache.value(for: scan, directoryID: 0, metric: .logical, sort: .sizeDescending, row: row)
            XCTAssertEqual(view.node(at: row)?.id, 12_000 - row)
            XCTAssertLessThanOrEqual(view.loadedCount, 4096)
        }
        let returned = try await cache.value(for: scan, directoryID: 0, metric: .logical, sort: .sizeDescending, selecting: 11_999)
        XCTAssertEqual(returned.rowByID[11_999], 1)
        XCTAssertEqual(returned.node(at: 1)?.id, 11_999)
    }
    func testIndexLifetimeRemovesTemporaryFiles() async throws {
        var scan: DiskSnapshot? = try DiskScanner().scan(root)
        let directory = scan!.index.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        scan = nil
        for _ in 0..<100 where FileManager.default.fileExists(atPath: directory.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
