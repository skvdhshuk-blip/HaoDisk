import Foundation

enum CleanupPolicy {
    static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let base = parent.standardizedFileURL.pathComponents
        let path = child.standardizedFileURL.pathComponents
        return path.count > base.count && path.starts(with: base)
    }

    static func protectedPath(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        let systemRoots: Set<String> = ["system", "library", "applications", "usr", "bin", "sbin", "etc", "private", "var", "dev", "network"]
        if let first = parts.first, systemRoots.contains(first) { return true }
        if parts.count > 2, parts[0] == "volumes", systemRoots.contains(parts[2]) { return true }
        let protected: Set<String> = ["library", ".trash", ".trashes", ".spotlight-v100", ".fseventsd"]
        return parts.contains { protected.contains($0) }
    }

    static func reason(for id: Int, in snapshot: DiskSnapshot) -> String? {
        let node = snapshot.nodes[id]
        if id == 0 { return "所选分析根目录不能加入清理。" }
        if snapshot.stoppedEarly { return "本次扫描尚未完整结束，请重新扫描后清理。" }
        if node.issueCount > 0 { return "此项目包含未读取的内容，暂不能清理。" }
        if node.identity.isLink { return "符号链接仅供分析，请在 Finder 中处理。" }
        if !node.identity.isDirectory && !node.identity.isRegular { return "此文件类型仅供分析。" }
        if snapshot.ancestors(of: id).contains(where: { snapshot.nodes[$0].isPackage }) {
            return "应用或资料包及其内容仅供分析。"
        }
        var pending = [id]
        while let next = pending.popLast() {
            let item = snapshot.nodes[next]
            if protectedPath(item.url) || item.isPackage {
                return "系统、Library 和应用资料包仅供分析，请在对应应用中管理。"
            }
            pending.append(contentsOf: item.children)
        }
        return nil
    }

    static func adding(_ id: Int, to selection: Set<Int>, in snapshot: DiskSnapshot) -> Set<Int> {
        guard reason(for: id, in: snapshot) == nil else { return selection }
        let ancestors = Set(snapshot.ancestors(of: id).dropLast())
        if !ancestors.isDisjoint(with: selection) { return selection }
        let url = snapshot.nodes[id].url
        return Set(selection.filter { !isDescendant(snapshot.nodes[$0].url, of: url) }).union([id])
    }
}

struct TrashOutcome: Sendable {
    let id: Int
    let name: String
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
                    guard fresh.isComplete, fresh.nodes.count == original.count,
                          fresh.nodes.allSatisfy({ original[$0.url.path] == $0.identity }) else {
                        throw CleanupError.refused("文件夹内容在扫描后发生变化，请重新扫描。")
                    }
                }
                try operation(node.url)
                results.append(TrashOutcome(id: id, name: node.name, error: nil))
            } catch {
                results.append(TrashOutcome(id: id, name: node.name, error: error.localizedDescription))
            }
        }
        return results
    }
}

enum CleanupError: LocalizedError {
    case refused(String)
    var errorDescription: String? { if case .refused(let reason) = self { return reason }; return nil }
}
