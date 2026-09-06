import Foundation
import Darwin

enum SizeMetric: String, CaseIterable, Identifiable, Sendable {
    case allocated = "占用空间"
    case logical = "文件大小"
    var id: Self { self }
}

enum DirectorySort: String, CaseIterable, Identifiable, Sendable {
    case sizeDescending = "大小：从大到小"
    case sizeAscending = "大小：从小到大"
    case nameAscending = "名称：升序"
    case nameDescending = "名称：降序"
    var id: Self { self }
    var byName: Bool { self == .nameAscending || self == .nameDescending }
    var ascending: Bool { self == .sizeAscending || self == .nameAscending }
}

struct FileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int

    static func read(_ url: URL) throws -> (FileIdentity, Int64) {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (FileIdentity(device: value.st_dev, inode: value.st_ino, mode: value.st_mode,
                             size: value.st_size, modifiedSeconds: value.st_mtimespec.tv_sec,
                             modifiedNanos: value.st_mtimespec.tv_nsec), Int64(value.st_blocks) * 512)
    }

    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    var isLink: Bool { mode & S_IFMT == S_IFLNK }
    var isRegular: Bool { mode & S_IFMT == S_IFREG }
    var key: String { "\(device):\(inode)" }
}

struct DiskNode: Identifiable, Sendable {
    let id: Int
    let url: URL
    let parent: Int?
    var identity: FileIdentity
    let isPackage: Bool
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64 = 0
    var descendantCount = 0
    var childCount = 0
    var issueCount = 0
    var isHardLinkDuplicate = false
    var state: NodeScanState = .complete
    var restriction: CleanupRestriction?
    var revision = 0

    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    var isDirectory: Bool { identity.isDirectory }
    var canNavigate: Bool { isDirectory && !identity.isLink }
    func bytes(_ metric: SizeMetric) -> Int64 { metric == .allocated ? allocatedBytes : logicalBytes }
}

struct ScanIssue: Identifiable, Sendable {
    let id: Int
    let path: String
    let message: String
}

struct ScanProgress: Equatable, Sendable {
    let count: Int
    let bytes: Int64
    let folder: String
}

struct VolumeCapacity: Equatable, Sendable {
    let total: Int64?
    let available: Int64?

    static func read(at url: URL) -> VolumeCapacity {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return VolumeCapacity(total: values?.volumeTotalCapacity.map(Int64.init),
                              available: values?.volumeAvailableCapacity.map(Int64.init))
    }
}

enum NodeScanState: Int, Sendable { case pending, scanning, complete, partial }

enum ScanStopReason: Equatable, Sendable {
    case cancelled
    var title: String { "扫描已停止" }
    var explanation: String { "当前仅显示停止前已读取的内容。可重新扫描以补全结果。" }
}

/// A small immutable summary. Node records live in the index, never in this snapshot.
struct DiskSnapshot: Sendable {
    let index: ScanIndex
    let root: DiskNode
    let issues: [ScanIssue]
    let stopReason: ScanStopReason?
    let elapsed: TimeInterval
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    var version: UUID { index.session }
    var issueCount: Int { root.issueCount }
    var stoppedEarly: Bool { stopReason != nil }
    var isComplete: Bool { root.state == .complete && issueCount == 0 }
}

struct DiskScanner: Sendable {
    func scan(_ requestedRoot: URL,
              cancelled: @Sendable () -> Bool = { false },
              progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> DiskSnapshot {
        let started = Date()
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let (identity, _) = try FileIdentity.read(root)
        guard identity.isDirectory else { throw ScanError.notDirectory }
        let index = try ScanIndex()
        return try index.access {
            let package = (try? root.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            let rootNode = DiskNode(id: 0, url: root, parent: nil, identity: identity, isPackage: package, state: .pending)
            try index.insert(rootNode, ownLogical: 0, ownAllocated: 0, insidePackage: package, protected: CleanupPolicy.protectedPath(root))
            var lastID = 0
            var issues: [ScanIssue] = []
            var allocated: Int64 = 0
            var lastProgress = Date.distantPast
            var stopped: ScanStopReason?
            let keys: [URLResourceKey] = [.isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            try index.execute("BEGIN IMMEDIATE")
            do {
                var cursor = -1
                while true {
                    if cancelled() { stopped = .cancelled; break }
                    let found = try autoreleasepool { () throws -> Bool in
                        var pending: DiskNode?
                        try index.rows("SELECT * FROM nodes WHERE id>? AND state=0 ORDER BY id LIMIT 1", [.int(Int64(cursor))]) { pending = ScanIndex.decode($0) }
                        guard let directory = pending else { return false }
                        cursor = directory.id
                        try index.rows("UPDATE nodes SET state=1 WHERE id=?", [.int(Int64(directory.id))])
                        let parentPackage = try index.integer("SELECT insidePackage FROM nodes WHERE id=?", [.int(Int64(directory.id))]) != 0
                        var enumerationError: Error?
                        do {
                            let enumerator = try DiskDirectoryReader(directory.url)
                            while true {
                                let more = try autoreleasepool { () throws -> Bool in
                                    if cancelled() { stopped = .cancelled; return false }
                                    guard let url = try enumerator.next() else { return false }
                                    do {
                                        let (itemIdentity, blocks) = try FileIdentity.read(url)
                                        let values = try url.resourceValues(forKeys: Set(keys))
                                        lastID += 1
                                        let isPackage = values.isPackage == true
                                        var node = DiskNode(id: lastID, url: url, parent: directory.id, identity: itemIdentity, isPackage: isPackage,
                                                            state: itemIdentity.isDirectory ? .pending : .complete)
                                        if itemIdentity.device != identity.device { node.state = .partial; node.issueCount = 1 }
                                        let inside = parentPackage || isPackage
                                        let logical = itemIdentity.isRegular || itemIdentity.isLink ? max(0, itemIdentity.size) : 0
                                        let bytes = itemIdentity.isLink ? max(0, blocks) : itemIdentity.isRegular ? max(0, Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? Int(blocks))) : 0
                                        let duplicate = try index.insert(node, ownLogical: logical, ownAllocated: bytes, insidePackage: inside, protected: CleanupPolicy.protectedPath(url))
                                        if !duplicate { allocated += bytes }
                                        if node.issueCount > 0, issues.count < 100 { issues.append(ScanIssue(id: issues.count, path: url.path, message: "跳过其他挂载卷，请单独选择该卷。")) }
                                    } catch let error as NSError where error.domain == NSPOSIXErrorDomain || error.domain == NSCocoaErrorDomain {
                                        try index.rows("UPDATE nodes SET ownIssues=ownIssues+1 WHERE id=?", [.int(Int64(directory.id))])
                                        if issues.count < 100 { issues.append(ScanIssue(id: issues.count, path: url.path, message: error.localizedDescription)) }
                                    }
                                    return true
                                }
                                if !more { break }
                                if lastID % 1024 == 0 { try index.execute("COMMIT; BEGIN IMMEDIATE") }
                                if Date().timeIntervalSince(lastProgress) >= 0.2 {
                                    lastProgress = Date()
                                    progress(ScanProgress(count: lastID, bytes: allocated, folder: directory.name))
                                }
                            }
                        } catch let error as NSError where error.domain == NSPOSIXErrorDomain || error.domain == NSCocoaErrorDomain {
                            enumerationError = error
                        }
                        if let enumerationError {
                            try index.rows("UPDATE nodes SET ownIssues=ownIssues+1 WHERE id=?", [.int(Int64(directory.id))])
                            if issues.count < 100 { issues.append(ScanIssue(id: issues.count, path: directory.url.path, message: enumerationError.localizedDescription)) }
                        }
                        if stopped != nil { return false }
                        try index.rows("UPDATE nodes SET enumerated=1 WHERE id=?", [.int(Int64(directory.id))])
                        return true
                    }
                    if !found { break }
                }
                progress(ScanProgress(count: lastID, bytes: allocated, folder: "整理统计结果"))
                try index.aggregateAll(lastID: lastID)
                try index.execute("COMMIT")
            } catch {
                try? index.execute("ROLLBACK")
                throw CleanupError.refused("扫描未完成。\(error.localizedDescription)")
            }
            let capacity = VolumeCapacity.read(at: root)
            guard let completeRoot = try index.node(0) else { throw ScanError.unreadable }
            return DiskSnapshot(index: index, root: completeRoot, issues: issues, stopReason: stopped, elapsed: Date().timeIntervalSince(started), totalCapacity: capacity.total, availableCapacity: capacity.available)
        }
    }
}

enum ScanError: LocalizedError {
    case notDirectory, unreadable
    var errorDescription: String? {
        switch self {
        case .notDirectory: return "请选择文件夹。"
        case .unreadable: return "无法读取这个文件夹，请重新选择并授权。"
        }
    }
}

/// FileManager enumerators silently omit AppleDouble (._) entries. Read directory entries directly.
final class DiskDirectoryReader {
    private let handle: UnsafeMutablePointer<DIR>
    private let directory: URL
    init(_ directory: URL) throws {
        self.directory = directory
        guard let handle = directory.withUnsafeFileSystemRepresentation({ opendir($0!) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.handle = handle
    }
    deinit { closedir(handle) }
    func next() throws -> URL? {
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                return nil
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name != "." && name != ".." { return directory.appendingPathComponent(name) }
        }
    }
}
