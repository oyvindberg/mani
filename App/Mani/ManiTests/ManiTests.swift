import Testing
import Foundation
@testable import Mani
@testable import ManiCore

// Tests against helper code that lives in the Mani app target — code that
// isn't reachable from the ManiCore unit-test bundle. Uses the newer Swift
// Testing framework that the Xcode template ships with.

// MARK: - PathTreeNode.tree

struct PathTreeNodeTests {

    @Test func emptyInput_givesEmptyTree() {
        let nodes = PathTreeNode.tree(from: [])
        #expect(nodes.isEmpty)
    }

    @Test func singleFileAtRoot() {
        let nodes = PathTreeNode.tree(from: [("README.md", .added)])
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "README.md")
        #expect(nodes[0].fullPath == "README.md")
        #expect(nodes[0].isDirectory == false)
        #expect(nodes[0].status == .added)
    }

    @Test func nestedFile_buildsDirectoryChain() {
        let nodes = PathTreeNode.tree(from: [("src/main/Foo.swift", .modified)])
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "src")
        #expect(nodes[0].isDirectory)
        #expect(nodes[0].children.count == 1)
        let mainDir = nodes[0].children[0]
        #expect(mainDir.name == "main")
        #expect(mainDir.isDirectory)
        let leaf = mainDir.children[0]
        #expect(leaf.name == "Foo.swift")
        #expect(leaf.fullPath == "src/main/Foo.swift")
        #expect(leaf.isDirectory == false)
    }

    @Test func multipleFilesShareDirectory() {
        let nodes = PathTreeNode.tree(from: [
            ("src/Foo.swift", .modified),
            ("src/Bar.swift", .added),
        ])
        #expect(nodes.count == 1)
        let src = nodes[0]
        #expect(src.name == "src")
        #expect(src.children.count == 2)
        let names = Set(src.children.map { $0.name })
        #expect(names == Set(["Foo.swift", "Bar.swift"]))
    }

    @Test func directoriesSortBeforeFiles() {
        // Mixed roots: a directory plus a top-level file. Tree builder sorts
        // directories first.
        let nodes = PathTreeNode.tree(from: [
            ("zzz.txt", .added),
            ("aaa/inner.txt", .added),
        ])
        #expect(nodes.count == 2)
        #expect(nodes[0].name == "aaa")
        #expect(nodes[0].isDirectory)
        #expect(nodes[1].name == "zzz.txt")
        #expect(nodes[1].isDirectory == false)
    }
}

// MARK: - GitChange.Status

struct GitChangeStatusTests {

    @Test func parsesAllStandardLetters() {
        let cases: [(Character, GitChange.Status)] = [
            ("M", .modified), ("A", .added), ("D", .deleted),
            ("R", .renamed),  ("C", .copied), ("T", .typeChanged),
            ("U", .unmerged),
        ]
        for (letter, expected) in cases {
            #expect(GitChange.Status(letter: letter) == expected)
        }
    }

    @Test func unknownLetterFallsThroughToOther() {
        let s = GitChange.Status(letter: "Z")
        #expect(s == .other("Z"))
        #expect(s.glyph == "Z")
    }
}

// MARK: - WorktreeFSWatcher lifecycle

struct WorktreeFSWatcherLifecycleTests {

    @Test func stopIsIdempotent() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mani-watcher-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let watcher = WorktreeFSWatcher(root: tmp) { /* no-op */ }
        watcher.start()
        watcher.stop()
        watcher.stop()  // Second call should be safe.
        // No crash = pass.
    }
}
