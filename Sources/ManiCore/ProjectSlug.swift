import Foundation

// Deterministic slug for a project name. Used by the managed-mode
// New Project sheet to derive:
//   - the default branch name for `git worktree add -b <slug>`
//   - the on-disk subdir under <repo>/<namespace>/<slug>/
//
// Rules:
//   1. Lowercase.
//   2. Replace any run of non-[a-z0-9] chars with a single '-'.
//   3. Trim leading/trailing hyphens.
//   4. If the result is empty (caller passed an all-symbols name),
//      fall back to "wip" — the same placeholder Mani uses elsewhere
//      for unnamed projects.

public func slugifyProjectName(_ name: String) -> String {
    let lowered = name.lowercased()
    var out = ""
    var lastWasHyphen = false
    for scalar in lowered.unicodeScalars {
        let isAllowed = (scalar >= "a" && scalar <= "z")
            || (scalar >= "0" && scalar <= "9")
        if isAllowed {
            out.unicodeScalars.append(scalar)
            lastWasHyphen = false
        } else if !lastWasHyphen {
            out.append("-")
            lastWasHyphen = true
        }
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "wip" : out
}
