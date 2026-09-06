import Foundation
import SQLite3

enum CleanupRestriction: Int, Sendable {
    case root = 1, unreadable, link, fileType, package, protectedContent
    var message: String {
        switch self {
        case .root: return "所选分析根目录不能加入清理。"
        case .unreadable: return "此项目包含未读取的内容，暂不能清理。"
        case .link: return "符号链接仅供分析，请在 Finder 中处理。"
        case .fileType: return "此文件类型仅供分析。"
        case .package: return "应用或资料包及其内容仅供分析。"
        case .protectedContent: return "此项目包含受保护的系统目录、用户资料库或废纸篓，仅供分析。"
        }
    }
}

enum CleanupPolicy {
    private static let systemRoots: Set<String> = ["system", "library", "applications", "usr", "bin", "sbin", "etc", "private", "var", "dev", "network"]
    private static let protectedComponents: Set<String> = [".trash", ".trashes", ".spotlight-v100", ".fseventsd"]
    static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let base = parent.standardizedFileURL.pathComponents
        let path = child.standardizedFileURL.pathComponents
        return path.count > base.count && path.starts(with: base)
    }

    static func protectedPath(_ url: URL) -> Bool {
        // Lexical normalization only. URL.standardizedFileURL may query the filesystem.
        var parts: [String] = []
        for part in url.pathComponents where part != "/" && part != "." {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part.lowercased()) }
        }
        // Match Library at its system or user-home location, not arbitrary project names.
        let volumePath = parts.count > 2 && parts[0] == "volumes" ? Array(parts.dropFirst(2)) : parts
        if let first = volumePath.first, systemRoots.contains(first) { return true }
        if volumePath.count >= 3, volumePath[0] == "users", volumePath[2] == "library" { return true }
        return parts.contains { protectedComponents.contains($0) }
    }

    static func reason(for id: Int, in nodes: [Int: DiskNode]) -> String? {
        guard let node = nodes[id] else { return "项目已更新，请重新选择。" }
        return node.restriction?.message
    }

    static func adding(_ node: DiskNode, to selection: Set<Int>, nodes: [Int: DiskNode]) -> Set<Int> {
        guard node.restriction == nil else { return selection }
        // Lexical paths in loaded records avoid subtree or filesystem queries.
        let prefix = node.url.path + "/"
        if selection.contains(where: { id in nodes[id].map { node.url.path.hasPrefix($0.url.path + "/") } == true }) { return selection }
        return Set(selection.filter { id in nodes[id].map { !$0.url.path.hasPrefix(prefix) } ?? false }).union([node.id])
    }
}

struct TrashOutcome: Sendable {
    let id: Int
    let name: String
    let url: URL
    let error: String?
}

struct CleanupResult: Sendable {
    let outcomes: [TrashOutcome]
    let snapshot: DiskSnapshot
    let updateError: String?
}

struct TrashService {
    /// One worker serializes validation, the irreversible operation, and its index update.
    func move(_ ids: Set<Int>, in snapshot: DiskSnapshot,
              operation: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> CleanupResult {
        snapshot.index.access {
            let index = snapshot.index
            var results: [TrashOutcome] = []
            var updateError: String?
            for id in ids.sorted() {
                do {
                    guard index.usable else { throw CleanupError.refused("分析结果已失效，请重新扫描。") }
                    guard let node = try index.node(id) else { continue }
                    do {
                        if let reason = node.restriction?.message { throw CleanupError.refused(reason) }
                        try validate(node, index: index)
                        try operation(node.url)
                    } catch {
                        results.append(TrashOutcome(id: id, name: node.name, url: node.url, error: error.localizedDescription))
                        continue
                    }
                    results.append(TrashOutcome(id: id, name: node.name, url: node.url, error: nil))
                    do { try index.removeTrashed(node) }
                    catch {
                        index.usable = false
                        updateError = "清理已完成，分析更新失败。请重新扫描后继续清理。\n\(error.localizedDescription)"
                    }
                } catch {
                    updateError = updateError ?? error.localizedDescription
                    break
                }
            }
            let root = (try? index.node(0)) ?? snapshot.root
            let capacity = VolumeCapacity.read(at: root.url)
            return CleanupResult(outcomes: results,
                snapshot: DiskSnapshot(index: index, root: root, issues: snapshot.issues, stopReason: snapshot.stopReason, elapsed: snapshot.elapsed, totalCapacity: capacity.total, availableCapacity: capacity.available), updateError: updateError)
        }
    }

    private func validate(_ node: DiskNode, index: ScanIndex) throws {
        let ancestors = try index.ancestors(node.id)
        guard let root = ancestors.first,
              CleanupPolicy.isDescendant(node.url.resolvingSymlinksInPath(), of: root.url.resolvingSymlinksInPath()) else {
            throw CleanupError.refused("项目已移出授权目录，请重新扫描。")
        }
        for ancestor in ancestors {
            let (current, _) = try FileIdentity.read(ancestor.url)
            guard current.device == ancestor.identity.device, current.inode == ancestor.identity.inode, current.mode == ancestor.identity.mode else {
                throw CleanupError.refused("路径已改变，请重新扫描。")
            }
        }
        guard try FileIdentity.read(node.url).0 == node.identity else { throw CleanupError.refused("项目在扫描后发生变化，请重新扫描。") }
        if node.isDirectory {
            var count = 0
            try index.rows("""
            WITH RECURSIVE folders(id) AS (SELECT ? UNION ALL SELECT n.id FROM nodes n JOIN folders f ON n.parent=f.id WHERE (n.mode & 61440)=16384)
            SELECT n.* FROM nodes n JOIN folders f ON n.id=f.id
            """, [.int(Int64(node.id))]) { statement in
                try autoreleasepool {
                    let folder = ScanIndex.decode(statement)
                    guard try FileIdentity.read(folder.url).0 == folder.identity else { throw CleanupError.refused("文件夹内容已发生变化，请重新扫描。") }
                    let reader = try DiskDirectoryReader(folder.url)
                    var directCount = 0
                    while true {
                        let more = try autoreleasepool { () throws -> Bool in
                            guard let url = try reader.next() else { return false }
                            let identity = try FileIdentity.read(url).0
                            guard let original = try index.node(path: url.path), original.parent == folder.id,
                                  original.identity == identity, identity.device == root.identity.device else {
                                throw CleanupError.refused("文件夹内容已发生变化，请重新扫描。")
                            }
                            directCount += 1
                            return true
                        }
                        if !more { break }
                    }
                    guard directCount == folder.childCount, try FileIdentity.read(folder.url).0 == folder.identity else {
                        throw CleanupError.refused("无法完整核对文件夹，或内容已发生变化，请重新扫描。")
                    }
                    count += directCount
                }
            }
            guard count == node.descendantCount else { throw CleanupError.refused("文件夹内容未完整读取，请重新扫描。") }
        }
    }
}

extension ScanIndex {
    func removeTrashed(_ node: DiskNode) throws {
        try transaction {
            try execute("CREATE TEMP TABLE IF NOT EXISTS removed(id INTEGER PRIMARY KEY); DELETE FROM removed;")
            try rows("INSERT INTO removed WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT n.id FROM nodes n JOIN tree t ON n.parent=t.id) SELECT id FROM tree", [.int(Int64(node.id))])
            var affected = Set(try ancestors(node.id).dropLast().map(\.id))
            // Only deleted hard-link owners with surviving aliases need reassignment.
            var cursor = -1
            while true {
                var owners: [(Int, Int64, Int64, Int64, Int64)] = []
                try rows("SELECT id,device,inode,ownLogical,ownAllocated FROM nodes WHERE id>? AND id IN removed AND duplicate=0 AND (mode & 61440)=32768 AND EXISTS(SELECT 1 FROM nodes a WHERE a.device=nodes.device AND a.inode=nodes.inode AND a.id NOT IN removed) ORDER BY id LIMIT 512", [.int(Int64(cursor))]) {
                    owners.append((Int(sqlite3_column_int64($0,0)), sqlite3_column_int64($0,1), sqlite3_column_int64($0,2), sqlite3_column_int64($0,3), sqlite3_column_int64($0,4)))
                }
                guard !owners.isEmpty else { break }
                for (id, device, inode, logical, allocated) in owners {
                    cursor = id
                    let survivor = Int(try integer("SELECT id FROM nodes WHERE device=? AND inode=? AND id NOT IN removed ORDER BY id LIMIT 1", [.int(device), .int(inode)]))
                    try rows("UPDATE nodes SET duplicate=0,logical=?,allocated=?,revision=revision+1 WHERE id=?", [.int(logical), .int(allocated), .int(Int64(survivor))])
                    affected.formUnion(try ancestors(survivor).dropLast().map(\.id))
                }
            }
            try execute("DELETE FROM ordering WHERE directory IN removed; DELETE FROM nodes WHERE id IN removed;")
            if let parentID = node.parent, let parent = try self.node(parentID) {
                let identity = try FileIdentity.read(parent.url).0
                guard identity.device == parent.identity.device, identity.inode == parent.identity.inode, identity.mode == parent.identity.mode else {
                    throw CleanupError.refused("父目录已改变，请重新扫描。")
                }
                try rows("UPDATE nodes SET size=?,sec=?,nano=? WHERE id=?", [.int(identity.size), .int(Int64(identity.modifiedSeconds)), .int(Int64(identity.modifiedNanos)), .int(Int64(parentID))])
            }
            for id in affected.sorted(by: >) {
                try aggregate(id)
                try rows("UPDATE nodes SET revision=revision+1 WHERE id=?", [.int(Int64(id))])
                try rows("DELETE FROM ordering WHERE directory=?", [.int(Int64(id))])
            }
            try execute("DELETE FROM removed")
        }
    }
}

enum CleanupError: LocalizedError {
    case refused(String)
    var errorDescription: String? { if case .refused(let reason) = self { return reason }; return nil }
}
