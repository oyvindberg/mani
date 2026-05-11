import Foundation
import ManiCore
import SwiftUI

// Persistent per-project archive of historical Claude conversations.
//
// Layout under ~/Library/Application Support/Mani/projects/<project-uuid>/:
//   sessions-index.json            tiny summary, read on every boot
//   sessions/<session-id>.jsonl.gz gzipped transcript copy
//
// Why this exists:
//   1. claude.ai's own cleanup deletes session JSONLs after some period,
//      but the user wants conversations from worktrees that have since
//      been moved/deleted to keep showing up under their project. We
//      copy + compress to a place WE control.
//   2. discoverHistoricalClaudeSessions previously walked every
//      ~/.claude/projects/*.jsonl on every boot — hundreds of MB of
//      file I/O. Reading sessions-index.json instead is microseconds.
//
// Atomicity:
//   - Index writes go to <path>.tmp, fsync, rename. Stale .tmp files
//     are tolerated; recovery just rewrites them.
//   - Transcript writes are gzipped to a .tmp file, then renamed. A
//     half-written .tmp is invisible (we only ever look for the final
//     name) and harmless.
//
// We never delete the source ~/.claude/projects/*.jsonl — claude itself
// uses those for --resume. We safe-guard a copy.
final class SafekeepingStore: ObservableObject {
    let projectsRoot: URL

    init(appSupportRoot: URL) throws {
        let url = appSupportRoot.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        self.projectsRoot = url
    }

    // MARK: - Index

    func indexURL(for projectId: UUID) -> URL {
        projectDir(projectId)
            .appendingPathComponent("sessions-index.json", isDirectory: false)
    }

    // Read the on-disk index; returns .empty if the file is missing or
    // corrupt. We accept a single .empty fallback rather than throwing
    // because the alternative is a boot-time crash on the very file we
    // wrote to make boots faster.
    func loadIndex(for projectId: UUID) -> SessionIndex {
        let url = indexURL(for: projectId)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SessionIndex.self, from: data)) ?? .empty
    }

    func writeIndex(_ index: SessionIndex, for projectId: UUID) throws {
        let dir = projectDir(projectId)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        let final = indexURL(for: projectId)
        let tmp = final.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: tmp, to: final)
    }

    // Upsert a single entry — keyed by sessionId, preserving entry order
    // so the index is stable on disk (helps diff-driven debugging).
    func upsert(_ entry: SessionIndexEntry, for projectId: UUID) throws {
        var index = loadIndex(for: projectId)
        if let i = index.entries.firstIndex(where: { $0.sessionId == entry.sessionId }) {
            index.entries[i] = entry
        } else {
            index.entries.append(entry)
        }
        try writeIndex(index, for: projectId)
    }

    // MARK: - Transcripts

    func transcriptURL(sessionId: String, for projectId: UUID) -> URL {
        sessionsDir(projectId)
            .appendingPathComponent("\(sessionId).jsonl.gz", isDirectory: false)
    }

    func hasTranscript(sessionId: String, for projectId: UUID) -> Bool {
        FileManager.default.fileExists(atPath:
            transcriptURL(sessionId: sessionId, for: projectId).path
        )
    }

    // gzip-copy `source` into the project's sessions dir. Returns the
    // uncompressed byte count (which the caller stores in the index
    // entry as transcriptBytes). Synchronous; intended to be called
    // off the main actor by the sweeper.
    @discardableResult
    func archiveTranscript(
        from source: URL,
        sessionId: String,
        for projectId: UUID
    ) throws -> Int {
        let dir = sessionsDir(projectId)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let final = transcriptURL(sessionId: sessionId, for: projectId)
        let tmp = final.appendingPathExtension("tmp")
        if FileManager.default.fileExists(atPath: tmp.path) {
            try FileManager.default.removeItem(at: tmp)
        }

        // gzip -c < source > tmp. We avoid a Swift gzip implementation
        // because the 5-min sweep cadence makes subprocess overhead a
        // non-issue and the resulting .gz files are inspectable with
        // standard tools (gzcat, less.gz, …).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        let inputHandle = try FileHandle(forReadingFrom: source)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: tmp)
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        try process.run()
        process.waitUntilExit()
        try? inputHandle.close()
        try? outputHandle.close()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(
                domain: "Mani.SafekeepingStore", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "gzip exited with status \(process.terminationStatus)"]
            )
        }

        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: tmp, to: final)

        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        return (attrs[.size] as? Int) ?? 0
    }

    // Decompress a safekept transcript into memory. Used by the
    // External Claude detail view to render previews without holding a
    // live FD on a potentially-gone-from-disk source. Synchronous;
    // call off the main actor.
    func readArchivedTranscript(
        sessionId: String, for projectId: UUID
    ) throws -> Data {
        let url = transcriptURL(sessionId: sessionId, for: projectId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Mani.SafekeepingStore", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "gzip -dc exited with status \(process.terminationStatus)"]
            )
        }
        return data
    }

    // MARK: - Paths

    private func projectDir(_ projectId: UUID) -> URL {
        projectsRoot.appendingPathComponent(
            projectId.uuidString, isDirectory: true
        )
    }

    private func sessionsDir(_ projectId: UUID) -> URL {
        projectDir(projectId)
            .appendingPathComponent("sessions", isDirectory: true)
    }
}
