import Foundation

enum CleanupRestriction: Sendable {
    case root, unreadable, link, fileType, package, protectedContent
    var message: String {
        switch self {
        case .root: return "所选分析根目录不能加入清理。"
        case .unreadable: return "此项目包含未读取的内容，暂不能清理。"
        case .link: return "符号链接仅供分析，请在 Finder 中处理。"
        case .fileType: return "此文件类型仅供分析。"
        case .package: return "应用或资料包及其内容仅供分析。"
        case .protectedContent: return "系统、Library 和应用资料包仅供分析，请在对应应用中管理。"
        }
    }
}

enum CleanupPolicy {
    private static let systemRoots: Set<String> = ["system", "library", "applications", "usr", "bin", "sbin", "etc", "private", "var", "dev", "network"]
    private static let protectedComponents: Set<String> = ["library", ".trash", ".trashes", ".spotlight-v100", ".fseventsd"]
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
        if let first = parts.first, systemRoots.contains(first) { return true }
        if parts.count > 2, parts[0] == "volumes", systemRoots.contains(parts[2]) { return true }
        return parts.contains { protectedComponents.contains($0) }
    }

    static func reason(for id: Int, in snapshot: DiskSnapshot) -> String? {
        snapshot.cleanupRestrictions[id]?.message
    }

    /// Scanner nodes are parent-before-child. Build once before publishing the snapshot.
    static func index(_ nodes: [DiskNode]) -> [CleanupRestriction?] {
        var insidePackage = [Bool](repeating: false, count: nodes.count)
        // Drain Foundation's temporary path objects per node on large scans.
        var protected = nodes.map { node in autoreleasepool { protectedPath(node.url) || node.isPackage } }
        for node in nodes {
            insidePackage[node.id] = node.isPackage || node.parent.map { insidePackage[$0] } == true
        }
        for node in nodes.reversed() {
            if let parent = node.parent, protected[node.id] { protected[parent] = true }
        }
        return nodes.map { node in
            if node.id == 0 { return .root }
            if node.issueCount > 0 { return .unreadable }
            if node.identity.isLink { return .link }
            if !node.isDirectory && !node.identity.isRegular { return .fileType }
            if insidePackage[node.id] { return .package }
            return protected[node.id] ? .protectedContent : nil
        }
    }

    static func adding(_ id: Int, to selection: Set<Int>, in snapshot: DiskSnapshot) -> Set<Int> {
        guard reason(for: id, in: snapshot) == nil else { return selection }
        let ancestors = Set(snapshot.ancestors(of: id).dropLast())
        if !ancestors.isDisjoint(with: selection) { return selection }
        return Set(selection.filter { !snapshot.ancestors(of: $0).contains(id) }).union([id])
    }
}

struct TrashOutcome: Sendable {
    let id: Int
    let name: String
    let url: URL
    let error: String?
}

struct TrashService {
    /// Validate again immediately before the system trash operation. Never fall back to removeItem.
    func move(_ ids: Set<Int>, in snapshot: DiskSnapshot,
              operation: (URL) throws -> Void = { url in
                  try FileManager.default.trashItem(at: url, resultingItemURL: nil)
              }) -> [TrashOutcome] {
        var results: [TrashOutcome] = []
        for id in ids.sorted() {
            let node = snapshot.nodes[id]
            do {
                if let reason = CleanupPolicy.reason(for: id, in: snapshot) { throw CleanupError.refused(reason) }
                let resolvedRoot = snapshot.root.url.resolvingSymlinksInPath()
                guard CleanupPolicy.isDescendant(node.url.resolvingSymlinksInPath(), of: resolvedRoot) else {
                    throw CleanupError.refused("项目已移出授权目录，请重新扫描。")
                }
                // Check the root and every ancestor, preventing a replaced parent from redirecting a deletion.
                for ancestor in snapshot.ancestors(of: id) {
                    let original = snapshot.nodes[ancestor]
                    let (current, _) = try FileIdentity.read(original.url)
                    guard current.device == original.identity.device, current.inode == original.identity.inode,
                          current.mode == original.identity.mode else {
                        throw CleanupError.refused("路径已改变，请重新扫描。")
                    }
                }
                let (current, _) = try FileIdentity.read(node.url)
                guard current == node.identity else { throw CleanupError.refused("项目在扫描后发生变化，请重新扫描。") }
                if node.isDirectory {
                    let fresh = try DiskScanner().scan(node.url)
                    var original: [String: FileIdentity] = [:]
                    var pending = [id]
                    while let next = pending.popLast() {
                        original[snapshot.nodes[next].url.path] = snapshot.nodes[next].identity
                        pending.append(contentsOf: snapshot.nodes[next].children)
                    }
                    guard fresh.isComplete else {
                        throw CleanupError.refused("无法完整核对所选文件夹，请检查权限或选择更小的目录。")
                    }
                    guard fresh.nodes.count == original.count,
                          fresh.nodes.allSatisfy({ original[$0.url.path] == $0.identity }) else {
                        throw CleanupError.refused("文件夹内容未完整读取或已发生变化，请选择它的上级目录重新扫描。")
                    }
                }
                try operation(node.url)
                results.append(TrashOutcome(id: id, name: node.name, url: node.url, error: nil))
            } catch {
                results.append(TrashOutcome(id: id, name: node.name, url: node.url, error: error.localizedDescription))
            }
        }
        return results
    }
}

enum CleanupError: LocalizedError {
    case refused(String)
    var errorDescription: String? { if case .refused(let reason) = self { return reason }; return nil }
}
