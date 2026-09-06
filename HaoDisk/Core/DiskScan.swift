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
    let identity: FileIdentity
    let isPackage: Bool
    var children: [Int] = []
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64 = 0
    var descendantCount = 0
    var issueCount = 0
    var isHardLinkDuplicate = false

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

struct ScanProgress: Sendable {
    let count: Int
    let bytes: Int64
    let folder: String
}

struct DiskSnapshot: Sendable {
    let nodes: [DiskNode]
    let issues: [ScanIssue]
    let issueCount: Int
    let stoppedEarly: Bool
    let elapsed: TimeInterval
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    var root: DiskNode { nodes[0] }
    var isComplete: Bool { !stoppedEarly && issueCount == 0 }

    func children(of id: Int, metric: SizeMetric, sort: DirectorySort = .sizeDescending) -> [DiskNode] {
        nodes[id].children.map { nodes[$0] }.sorted {
            if !sort.byName, $0.bytes(metric) != $1.bytes(metric) {
                return sort.ascending ? $0.bytes(metric) < $1.bytes(metric) : $0.bytes(metric) > $1.bytes(metric)
            }
            let order = $0.name.localizedStandardCompare($1.name)
            return sort == .nameDescending ? order == .orderedDescending : order == .orderedAscending
        }
    }

    func ancestors(of id: Int) -> [Int] {
        var result = [id]
        var parent = nodes[id].parent
        while let value = parent {
            result.append(value)
            parent = nodes[value].parent
        }
        return result.reversed()
    }
}

/// One worker owns all mutable scan state. Nothing reads file contents.
struct DiskScanner: Sendable {
    let maximumNodes: Int
    init(maximumNodes: Int = 500_000) { self.maximumNodes = max(1, maximumNodes) }

    func scan(_ requestedRoot: URL,
              cancelled: @Sendable () -> Bool = { false },
              progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> DiskSnapshot {
        let started = Date()
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let (rootIdentity, _) = try FileIdentity.read(root)
        guard rootIdentity.isDirectory else { throw ScanError.notDirectory }
        let manager = FileManager()
        let keys: [URLResourceKey] = [.isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var nodes = [DiskNode(id: 0, url: root, parent: nil, identity: rootIdentity,
                              isPackage: (try? root.resourceValues(forKeys: [.isPackageKey]).isPackage) == true)]
        var directories = [root.path: 0]
        var identities = Set<String>()
        var issues: [ScanIssue] = []
        var issueCount = 0
        var stopped = false
        var allocated: Int64 = 0
        var lastProgress = Date.distantPast

        func record(_ url: URL, _ message: String, at node: Int) {
            issueCount += 1
            nodes[node].issueCount += 1
            if issues.count < 100 { issues.append(ScanIssue(id: issueCount, path: url.path, message: message)) }
        }

        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                  options: [], errorHandler: { url, error in
            let owner = directories[url.path] ?? directories[url.deletingLastPathComponent().path] ?? 0
            record(url, error.localizedDescription, at: owner)
            return true
        }) else { throw ScanError.unreadable }

        while true {
            if cancelled() { stopped = true; break }
            guard let url = enumerator.nextObject() as? URL else { break }
            if nodes.count >= maximumNodes {
                stopped = true
                record(root, "项目数量达到 \(maximumNodes) 上限，请选择更小的目录。", at: 0)
                break
            }
            let parent = directories[url.deletingLastPathComponent().path] ?? 0
            do {
                let (identity, blocks) = try FileIdentity.read(url)
                let values = try url.resourceValues(forKeys: Set(keys))
                var node = DiskNode(id: nodes.count, url: url, parent: parent,
                                    identity: identity, isPackage: values.isPackage == true)
                if identity.device != rootIdentity.device {
                    enumerator.skipDescendants()
                    node.issueCount = 1
                    issueCount += 1
                    if issues.count < 100 {
                        issues.append(ScanIssue(id: issueCount, path: url.path, message: "跳过其他挂载卷，请单独选择该卷。"))
                    }
                } else if identity.isDirectory {
                    directories[url.path] = node.id
                } else if identity.isRegular || identity.isLink {
                    if identity.isLink { enumerator.skipDescendants() }
                    let duplicate = identity.isRegular && !identities.insert(identity.key).inserted
                    node.isHardLinkDuplicate = duplicate
                    if !duplicate {
                        node.logicalBytes = max(0, identity.size)
                        // Foundation accounts for compressed/sparse files; stat is the metadata fallback.
                        node.allocatedBytes = identity.isLink ? max(0, blocks) : max(0, Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? Int(blocks)))
                        allocated += node.allocatedBytes
                    }
                }
                nodes[parent].children.append(node.id)
                nodes.append(node)
            } catch {
                enumerator.skipDescendants()
                record(url, error.localizedDescription, at: parent)
            }
            if Date().timeIntervalSince(lastProgress) >= 0.12 {
                lastProgress = Date()
                progress(ScanProgress(count: nodes.count - 1, bytes: allocated, folder: url.deletingLastPathComponent().lastPathComponent))
            }
        }
        if nodes.count > 1 {
            for id in stride(from: nodes.count - 1, through: 1, by: -1) {
                guard let parent = nodes[id].parent else { continue }
                nodes[parent].allocatedBytes += nodes[id].allocatedBytes
                nodes[parent].logicalBytes += nodes[id].logicalBytes
                nodes[parent].descendantCount += nodes[id].descendantCount + 1
                nodes[parent].issueCount += nodes[id].issueCount
            }
        }
        let capacity = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return DiskSnapshot(nodes: nodes, issues: issues, issueCount: issueCount, stoppedEarly: stopped,
                            elapsed: Date().timeIntervalSince(started),
                            totalCapacity: capacity?.volumeTotalCapacity.map(Int64.init),
                            availableCapacity: capacity?.volumeAvailableCapacity.map(Int64.init))
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
