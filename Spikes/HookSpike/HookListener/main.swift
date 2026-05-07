import Foundation
import Darwin

// HookListener: AF_UNIX server. Accepts connections from HookShim,
// reads to EOF, prints each envelope with a wall-clock timestamp.
// Run in one terminal while `claude` runs in another with the
// sandboxed HOME pointing at our forged settings.json.

let socketPath = "/tmp/mani-hook-spike.sock"

setbuf(stdout, nil)  // line-buffered output even when redirected to a file
unlink(socketPath)

let sock = socket(AF_UNIX, SOCK_STREAM, 0)
guard sock >= 0 else {
    perror("socket")
    exit(1)
}

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
let bound = withUnsafePointer(to: &addr) { addrPtr in
    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        bind(sock, sockaddrPtr, addrLen)
    }
}
guard bound == 0 else {
    perror("bind")
    exit(1)
}

guard listen(sock, 16) == 0 else {
    perror("listen")
    exit(1)
}

print("HookListener listening on \(socketPath)")
print("Press Ctrl-C to stop. (Socket file will be left behind; next run unlinks it.)")
print("")

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

while true {
    let client = accept(sock, nil, nil)
    if client < 0 { continue }

    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(client, &buf, 4096)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    close(client)

    let ts = formatter.string(from: Date())
    if let str = String(data: data, encoding: .utf8) {
        print("[\(ts)] \(str)")
    } else {
        print("[\(ts)] (\(data.count) non-utf8 bytes)")
    }
}
