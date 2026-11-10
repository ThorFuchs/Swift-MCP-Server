// SPDX-License-Identifier: Apache-2.0
// Test-only portability helpers. The library itself never changes process signal state.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import SystemPackage

/// Pipe with the requested flags (`FileDescriptor.pipe(options:)` needs macOS 27).
func testPipe(nonBlocking: Bool = true) throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
    let pair = try FileDescriptor.pipe()
    for raw in [pair.readEnd.rawValue, pair.writeEnd.rawValue] {
        _ = fcntl(raw, F_SETFD, FD_CLOEXEC)
        if nonBlocking { _ = fcntl(raw, F_SETFL, fcntl(raw, F_GETFL) | O_NONBLOCK) }
    }
    return pair
}

/// Darwin's per-open-file SIGPIPE flag. Linux has none: reads report 0, writes succeed.
func getNoSigPipe(_ raw: Int32) -> Int32 {
    #if canImport(Darwin)
    return fcntl(raw, F_GETNOSIGPIPE)
    #else
    return 0
    #endif
}
@discardableResult func setNoSigPipe(_ raw: Int32, _ value: Int32 = 1) -> Int32 {
    #if canImport(Darwin)
    return fcntl(raw, F_SETNOSIGPIPE, value)
    #else
    // Test host only: writes to a child's closed stdin must not kill the test process.
    _ = signal(SIGPIPE, SIG_IGN)
    return 0
    #endif
}
