import Foundation
import SQLite3

/// Accessed by background workers only. The lock serializes a scan, query, or cleanup transaction.
final class ScanIndex: @unchecked Sendable {
    let session = UUID()
    let directory: URL
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()
    private(set) var queryCount = 0
    var usable = true
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let housekeeping: Void = {
        let base = cacheDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // A process owns its indexes; never remove a second running instance's files.
        for url in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            if let pid = Int32(url.lastPathComponent.split(separator: "-").first ?? ""), kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }()
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HaoDisk/ScanIndexes", isDirectory: true)
    }

    static func removeCurrentProcessIndexes() {
        let prefix = "\(getpid())-"
        for url in (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    init() throws {
        _ = Self.housekeeping
        directory = Self.cacheDirectory.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(directory.appendingPathComponent("scan.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CleanupError.refused("无法创建临时扫描索引。")
        }
        sqlite3_create_collation(db, "NATURAL_NAME", SQLITE_UTF8, nil) { _, na, a, nb, b in
            guard let a, let b else { return 0 }
            return autoreleasepool {
                let lhs = String(decoding: UnsafeRawBufferPointer(start: a, count: Int(na)), as: UTF8.self)
                let rhs = String(decoding: UnsafeRawBufferPointer(start: b, count: Int(nb)), as: UTF8.self)
                return Int32(lhs.localizedStandardCompare(rhs).rawValue)
            }
        }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-8192; PRAGMA temp_store=FILE;")
        try execute("""
        CREATE TABLE nodes (
          id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, parent INTEGER,
          device INTEGER, inode INTEGER, mode INTEGER, size INTEGER, sec INTEGER, nano INTEGER,
          package INTEGER, insidePackage INTEGER, ownProtected INTEGER, protected INTEGER,
          ownLogical INTEGER, ownAllocated INTEGER, logical INTEGER, allocated INTEGER,
          descendants INTEGER DEFAULT 0, childCount INTEGER DEFAULT 0, ownIssues INTEGER DEFAULT 0, issues INTEGER DEFAULT 0,
          state INTEGER, enumerated INTEGER DEFAULT 0, duplicate INTEGER DEFAULT 0, restriction INTEGER DEFAULT 0, revision INTEGER DEFAULT 0
        );
        CREATE INDEX parents ON nodes(parent);
        CREATE INDEX identities ON nodes(device,inode) WHERE (mode & 61440)=32768;
        CREATE TABLE ordering (directory INTEGER, revision INTEGER, metric TEXT, sorting TEXT, row INTEGER, node INTEGER,
          PRIMARY KEY(directory,metric,sorting,row));
        CREATE INDEX row_lookup ON ordering(directory,metric,sorting,node);
        """)
    }

    private final class Disposal: @unchecked Sendable {
        let database: OpaquePointer?
        let statements: [OpaquePointer]
        let directory: URL
        init(database: OpaquePointer?, statements: [OpaquePointer], directory: URL) {
            self.database = database; self.statements = statements; self.directory = directory
        }
        func close() {
            for stmt in statements { sqlite3_finalize(stmt) }
            sqlite3_close(database)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    deinit {
        let disposal = Disposal(database: db, statements: Array(statements.values), directory: directory)
        DispatchQueue.global(qos: .utility).async { disposal.close() }
    }

    func access<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func failure() -> Error { CleanupError.refused("扫描索引读写失败：\(String(cString: sqlite3_errmsg(db)))。请重新扫描。") }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    @discardableResult func rows(_ sql: String, _ values: [SQLValue] = [], visit: (OpaquePointer) throws -> Void = { _ in }) throws -> Int {
        queryCount += 1
        let stmt: OpaquePointer
        if let cached = statements[sql] { stmt = cached }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
            stmt = prepared; statements[sql] = stmt
        }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        for (i, value) in values.enumerated() {
            let rc: Int32
            switch value {
            case .int(let n): rc = sqlite3_bind_int64(stmt, Int32(i + 1), n)
            case .text(let s): rc = sqlite3_bind_text(stmt, Int32(i + 1), s, -1, Self.transient)
            case .null: rc = sqlite3_bind_null(stmt, Int32(i + 1))
            }
            guard rc == SQLITE_OK else { throw failure() }
        }
        var count = 0
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return count }
            guard rc == SQLITE_ROW else { throw failure() }
            try visit(stmt); count += 1
        }
    }
    func integer(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        var result: Int64 = 0
        try rows(sql, values) { result = sqlite3_column_int64($0, 0) }
        return result
    }
    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }

    @discardableResult func insert(_ node: DiskNode, ownLogical: Int64, ownAllocated: Int64, insidePackage: Bool, protected: Bool) throws -> Bool {
        let identity = node.identity
        let duplicate = try identity.isRegular && integer("SELECT EXISTS(SELECT 1 FROM nodes WHERE device=? AND inode=? AND (mode & 61440)=32768)", [.int(Int64(identity.device)), .int(Int64(bitPattern: identity.inode))]) != 0
        try rows("""
        INSERT INTO nodes(id,path,name,parent,device,inode,mode,size,sec,nano,package,insidePackage,ownProtected,protected,
        ownLogical,ownAllocated,logical,allocated,state,enumerated,duplicate,ownIssues,issues)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.int(Int64(node.id)), .text(node.url.path), .text(node.name), node.parent.map { .int(Int64($0)) } ?? .null,
              .int(Int64(identity.device)), .int(Int64(bitPattern: identity.inode)), .int(Int64(identity.mode)), .int(identity.size),
              .int(Int64(identity.modifiedSeconds)), .int(Int64(identity.modifiedNanos)), .bool(node.isPackage), .bool(insidePackage), .bool(protected), .bool(protected),
              .int(ownLogical), .int(ownAllocated), .int(duplicate ? 0 : ownLogical), .int(duplicate ? 0 : ownAllocated),
              .int(Int64(node.state.rawValue)), .bool(!node.canNavigate), .bool(duplicate), .int(Int64(node.issueCount)), .int(Int64(node.issueCount))])
        return duplicate
    }

    func node(_ id: Int) throws -> DiskNode? { try find("id=?", [.int(Int64(id))]) }
    func node(path: String) throws -> DiskNode? { try find("path=?", [.text(path)]) }
    private func find(_ clause: String, _ values: [SQLValue]) throws -> DiskNode? {
        var result: DiskNode?
        try rows("SELECT * FROM nodes WHERE \(clause)", values) { result = Self.decode($0) }
        return result
    }
    static func decode(_ stmt: OpaquePointer) -> DiskNode {
        func n(_ c: Int32) -> Int64 { sqlite3_column_int64(stmt, c) }
        let identity = FileIdentity(device: Int32(n(4)), inode: UInt64(bitPattern: n(5)), mode: UInt16(n(6)), size: n(7), modifiedSeconds: Int(n(8)), modifiedNanos: Int(n(9)))
        return DiskNode(id: Int(n(0)), url: URL(fileURLWithPath: text(stmt, 1)), parent: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(n(3)), identity: identity,
                        isPackage: n(10) != 0, logicalBytes: n(16), allocatedBytes: n(17), descendantCount: Int(n(18)), childCount: Int(n(19)), issueCount: Int(n(21)), isHardLinkDuplicate: n(24) != 0,
                        state: NodeScanState(rawValue: Int(n(22))) ?? .partial, restriction: CleanupRestriction(rawValue: Int(n(25))), revision: Int(n(26)))
    }
    func ancestors(_ id: Int) throws -> [DiskNode] {
        var result: [DiskNode] = []
        var next: Int? = id
        while let id = next, let node = try node(id) { result.append(node); next = node.parent }
        return result.reversed()
    }

    /// Parent-before-child IDs permit a bounded reverse pass; children are never materialized.
    func aggregateAll(lastID: Int) throws {
        try execute("UPDATE nodes SET restriction=CASE WHEN state!=2 OR issues>0 THEN 2 WHEN (mode & 61440)=40960 THEN 3 WHEN (mode & 61440) NOT IN (16384,32768) THEN 4 WHEN insidePackage=1 THEN 5 WHEN protected=1 THEN 6 ELSE 0 END")
        var cursor = lastID + 1
        while true {
            var ids: [Int] = []
            try rows("SELECT id FROM nodes WHERE id<? AND (mode & 61440)=16384 ORDER BY id DESC LIMIT 512", [.int(Int64(cursor))]) { ids.append(Int(sqlite3_column_int64($0, 0))) }
            if ids.isEmpty { break }
            for id in ids { try aggregate(id) }
            cursor = ids.last!
        }
        try execute("CREATE INDEX IF NOT EXISTS allocated_order ON nodes(parent,allocated DESC,id); CREATE INDEX IF NOT EXISTS logical_order ON nodes(parent,logical DESC,id);")
    }
    func aggregate(_ id: Int) throws {
        try rows("""
        UPDATE nodes SET
          logical=CASE WHEN duplicate=1 THEN 0 ELSE ownLogical END + COALESCE((SELECT SUM(logical) FROM nodes c WHERE c.parent=nodes.id),0),
          allocated=CASE WHEN duplicate=1 THEN 0 ELSE ownAllocated END + COALESCE((SELECT SUM(allocated) FROM nodes c WHERE c.parent=nodes.id),0),
          descendants=COALESCE((SELECT SUM(descendants+1) FROM nodes c WHERE c.parent=nodes.id),0),
          childCount=(SELECT COUNT(*) FROM nodes c WHERE c.parent=nodes.id),
          issues=ownIssues+COALESCE((SELECT SUM(issues) FROM nodes c WHERE c.parent=nodes.id),0),
          protected=MAX(ownProtected,COALESCE((SELECT MAX(protected) FROM nodes c WHERE c.parent=nodes.id),0)),
          state=CASE WHEN enumerated=0 THEN CASE WHEN state=0 THEN 0 ELSE 3 END
            WHEN ownIssues>0 OR EXISTS(SELECT 1 FROM nodes c WHERE c.parent=nodes.id AND c.state!=2) THEN 3 ELSE 2 END
        WHERE id=?
        """, [.int(Int64(id))])
        try rows("""
        UPDATE nodes SET restriction=CASE WHEN id=0 THEN 1 WHEN state!=2 OR issues>0 THEN 2
          WHEN (mode & 61440)=40960 THEN 3 WHEN (mode & 61440) NOT IN (16384,32768) THEN 4
          WHEN insidePackage=1 THEN 5 WHEN protected=1 THEN 6 ELSE 0 END WHERE id=?
        """, [.int(Int64(id))])
    }

    private final class CancellationProbe {
        let check: () -> Bool
        init(_ check: @escaping () -> Bool) { self.check = check }
    }
    func withCancellation<T>(_ cancelled: () -> Bool, body: () throws -> T) throws -> T {
        try withoutActuallyEscaping(cancelled) { check in
            let probe = CancellationProbe(check)
            sqlite3_progress_handler(db, 1000, { pointer in
                guard let pointer else { return 0 }
                return Unmanaged<CancellationProbe>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
            }, Unmanaged.passUnretained(probe).toOpaque())
            defer { sqlite3_progress_handler(db, 0, nil, nil); withExtendedLifetime(probe) {} }
            do { return try body() }
            catch { if cancelled() { throw CancellationError() }; throw error }
        }
    }

    func prepareOrdering(directory: DiskNode, metric: SizeMetric, sort: DirectorySort, cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        let args: [SQLValue] = [.int(Int64(directory.id)), .text(metric.rawValue), .text(sort.rawValue)]
        if try integer("SELECT COUNT(*) FROM ordering WHERE directory=? AND metric=? AND sorting=? AND revision=?", args + [.int(Int64(directory.revision))]) == directory.childCount { return }
        let size = metric == .allocated ? "allocated" : "logical"
        let order = sort.byName ? "name COLLATE NATURAL_NAME \(sort.ascending ? "ASC" : "DESC"),id" : "\(size) \(sort.ascending ? "ASC" : "DESC"),name COLLATE NATURAL_NAME,id"
        try withCancellation(cancelled) { try transaction {
            try rows("DELETE FROM ordering WHERE directory=? AND metric=? AND sorting=?", args)
            try rows("INSERT INTO ordering SELECT ?,?,?,?,ROW_NUMBER() OVER(ORDER BY \(order))-1,id FROM nodes WHERE parent=?", [.int(Int64(directory.id)), .int(Int64(directory.revision)), .text(metric.rawValue), .text(sort.rawValue), .int(Int64(directory.id))])
            if cancelled() { throw CancellationError() }
        } }
    }
    func page(_ key: DirectoryKey, start: Int, count: Int = 512) throws -> [Int: DiskNode] {
        var result: [Int: DiskNode] = [:]
        try rows("SELECT n.*,o.row FROM ordering o JOIN nodes n ON n.id=o.node WHERE o.directory=? AND o.metric=? AND o.sorting=? AND o.revision=? AND o.row>=? AND o.row<? ORDER BY o.row", [.int(Int64(key.directoryID)), .text(key.metric.rawValue), .text(key.sort.rawValue), .int(Int64(key.revision)), .int(Int64(start)), .int(Int64(start + count))]) { result[Int(sqlite3_column_int64($0, 27))] = Self.decode($0) }
        return result
    }
    func row(_ id: Int, key: DirectoryKey) throws -> Int? {
        var result: Int?
        try rows("SELECT row FROM ordering WHERE directory=? AND metric=? AND sorting=? AND node=? AND revision=?", [.int(Int64(key.directoryID)), .text(key.metric.rawValue), .text(key.sort.rawValue), .int(Int64(id)), .int(Int64(key.revision))]) { result = Int(sqlite3_column_int64($0, 0)) }
        return result
    }
}

enum SQLValue {
    case int(Int64), text(String), null
    static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }
}
