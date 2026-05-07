import Foundation
import Darwin

// HookShim: invoked by Claude Code via hooks in settings.json.
// Reads the hook payload from stdin, wraps it in an envelope including
// MANI_TASK_ID and a timestamp, and POSTs it to a Unix domain socket.
// Always exits 0 — see docs/claude-integration.md "the shim must exit 0
// on any failure path. Hooks blocking Claude is worse than missing one."

let socketPath = "/tmp/mani-hook-spike.sock"

let payload = FileHandle.standardInput.readDataToEndOfFile()

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

var envelope: [String: Any] = [
    "received_at": formatter.string(from: Date()),
    "task_id": ProcessInfo.processInfo.environment["MANI_TASK_ID"] ?? "(unset)",
    "payload_bytes": payload.count,
]
if let s = String(data: payload, encoding: .utf8) {
    envelope["payload"] = s
}

guard let envelopeData = try? JSONSerialization.data(
    withJSONObject: envelope,
    options: [.sortedKeys]
) else { exit(0) }

let sock = socket(AF_UNIX, SOCK_STREAM, 0)
guard sock >= 0 else { exit(0) }
defer { close(sock) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
        for i in 0..<min(pathBytes.count, 103) {
            cptr[i] = CChar(pathBytes[i])
        }
        cptr[min(pathBytes.count, 103)] = 0
    }
}

let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) { addrPtr in
    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(sock, sockaddrPtr, addrLen)
    }
}
guard connected == 0 else { exit(0) }

envelopeData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    guard let base = raw.baseAddress else { return }
    var remaining = envelopeData.count
    var ptr = base
    while remaining > 0 {
        let n = write(sock, ptr, remaining)
        if n <= 0 { break }
        remaining -= n
        ptr = ptr.advanced(by: n)
    }
}

exit(0)
