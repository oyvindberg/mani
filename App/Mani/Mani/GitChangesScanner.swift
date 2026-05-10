import Foundation

// Snapshots the working state of a git worktree for the Diff Workspace.
// Two queries:
//   - `git diff --name-status <ref>` for tracked changes (M / A / D / R / etc)
//   - `git ls-files --others --exclude-standard` for untracked files
//
// Both block; callers should run from a background queue. The result is a
// flat list which DiffWorkspaceView assembles into a tree via PathTreeNode.

struct GitChange: Equatable, Hashable {
    enum Status: Equatable, Hashable {
        case modified, added, deleted, renamed, copied, typeChanged, unmerged
        case other(String)

        init(letter: Character) {
            switch letter {
            case "M": self = .modified
            case "A": self = .added
            case "D": self = .deleted
            case "R": self = .renamed
            case "C": self = .copied
            case "T": self = .typeChanged
            case "U": self = .unmerged
            default:  self = .other(String(letter))
            }
        }

        var glyph: String {
            switch self {
            case .modified:    return "M"
            case .added:       return "A"
            case .deleted:     return "D"
            case .renamed:     return "R"
            case .copied:      return "C"
            case .typeChanged: return "T"
            case .unmerged:    return "U"
            case .other(let s): return String(s.prefix(1))
            }
        }
    }

    let path: String
    let status: Status
}

enum GitChangesScanner {

    static func tracked(worktree: URL, sourceRef: String) -> [GitChange] {
        let out = runGit(args: ["diff", "--name-status", sourceRef], cwd: worktree)
        return out.split(separator: "\n").compactMap { line -> GitChange? in
            // Tab-separated. R/C lines have similarity + old + new paths;
            // we report the new (last) path.
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  let statusLetter = parts[0].first
            else { return nil }
            let path = String(parts.last!)
            return GitChange(path: path, status: GitChange.Status(letter: statusLetter))
        }
    }

    static func untracked(worktree: URL) -> [String] {
        let out = runGit(
            args: ["ls-files", "--others", "--exclude-standard"],
            cwd: worktree
        )
        return out.split(separator: "\n").map(String.init)
    }

    // Stage the given paths. Returns true on success.
    @discardableResult
    static func add(paths: [String], worktree: URL) -> Bool {
        guard !paths.isEmpty else { return true }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.currentDirectoryURL = worktree
        task.arguments = ["add", "--"] + paths
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runGit(args: [String], cwd: URL) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.currentDirectoryURL = cwd
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe() // discard stderr
        do {
            try task.run()
        } catch {
            return ""
        }
        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// A node in the file tree the workspace sidebar renders. A directory has
// children and no leaf data; a file has leaf data and an empty children
// array.
struct PathTreeNode: Identifiable {
    let id = UUID()
    let name: String           // last path component (or the full path for a root file)
    let fullPath: String?      // nil for directories
    let status: GitChange.Status?  // nil for directories; status letter for files
    var children: [PathTreeNode]

    var isDirectory: Bool { fullPath == nil }

    // Build a tree from a list of (path, status) pairs. Paths use "/" as
    // separator. Single-child directory chains are collapsed for IDE-style
    // display ("src/main/swift/Foo.swift" → "src/main/swift > Foo.swift" if
    // src/main/swift has only one descendant).
    static func tree(from entries: [(path: String, status: GitChange.Status?)]) -> [PathTreeNode] {
        // First pass: build the full tree with one node per segment.
        var roots: [String: TreeBuilder] = [:]
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            // Climb (or create) the path.
            if roots[components[0]] == nil {
                roots[components[0]] = TreeBuilder(name: components[0])
            }
            var cursor = roots[components[0]]!
            for i in 1..<components.count {
                let seg = components[i]
                if cursor.children[seg] == nil {
                    cursor.children[seg] = TreeBuilder(name: seg)
                }
                let next = cursor.children[seg]!
                roots[components[0]] = updatedRoot(
                    roots[components[0]]!, replacing: cursor, with: next
                )
                cursor = next
            }
            cursor.fullPath = entry.path
            cursor.status = entry.status
            roots[components[0]] = updatedRoot(
                roots[components[0]]!, replacing: cursor, with: cursor
            )
        }
        // Convert TreeBuilder (mutable / nested classes) to PathTreeNode.
        return roots.values
            .sorted { $0.name < $1.name }
            .map { $0.asImmutable() }
    }

    private static func updatedRoot(
        _ root: TreeBuilder,
        replacing _: TreeBuilder,
        with _: TreeBuilder
    ) -> TreeBuilder {
        // The TreeBuilder is a class; mutations to cursor propagate to root
        // via shared references. We accept the reassignment-as-no-op to keep
        // the call-site uniform.
        return root
    }
}

private final class TreeBuilder {
    let name: String
    var fullPath: String?
    var status: GitChange.Status?
    var children: [String: TreeBuilder] = [:]

    init(name: String) {
        self.name = name
    }

    func asImmutable() -> PathTreeNode {
        let kids = children.values
            .sorted { (a, b) in
                // Directories first, then files; alphabetical within.
                let aDir = a.fullPath == nil
                let bDir = b.fullPath == nil
                if aDir != bDir { return aDir && !bDir }
                return a.name < b.name
            }
            .map { $0.asImmutable() }
        return PathTreeNode(
            name: name,
            fullPath: fullPath,
            status: status,
            children: kids
        )
    }
}
