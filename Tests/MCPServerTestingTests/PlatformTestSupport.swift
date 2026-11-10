// SPDX-License-Identifier: Apache-2.0
// Test-only portability helpers. The library itself never changes process signal state.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

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
