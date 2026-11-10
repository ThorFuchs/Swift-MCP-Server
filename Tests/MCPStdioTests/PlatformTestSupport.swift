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

/// `SOCK_STREAM` as an `Int32`; Glibc imports it as the `__socket_type` enum.
let testStreamSocketType: Int32 = {
    #if canImport(Glibc)
    return Int32(SOCK_STREAM.rawValue)
    #else
    return SOCK_STREAM
    #endif
}()

/// Module-qualified libc calls for code where a bare name would resolve to a method.
enum SystemCall {
    #if canImport(Darwin)
    static func close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Darwin.read(fd, buffer, count) }
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { Darwin.write(fd, buffer, count) }
    static func recv<F: BinaryInteger>(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ flags: F) -> Int { Darwin.recv(fd, buffer, count, Int32(flags)) }
    static func shutdown<H: BinaryInteger>(_ fd: Int32, _ how: H) -> Int32 { Darwin.shutdown(fd, Int32(how)) }
    #elseif canImport(Glibc)
    static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Glibc.read(fd, buffer, count) }
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { Glibc.write(fd, buffer, count) }
    static func recv<F: BinaryInteger>(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ flags: F) -> Int { Glibc.recv(fd, buffer, count, Int32(flags)) }
    static func shutdown<H: BinaryInteger>(_ fd: Int32, _ how: H) -> Int32 { Glibc.shutdown(fd, Int32(how)) }
    #elseif canImport(Musl)
    static func close(_ fd: Int32) -> Int32 { Musl.close(fd) }
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Musl.read(fd, buffer, count) }
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { Musl.write(fd, buffer, count) }
    static func recv<F: BinaryInteger>(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ flags: F) -> Int { Musl.recv(fd, buffer, count, Int32(flags)) }
    static func shutdown<H: BinaryInteger>(_ fd: Int32, _ how: H) -> Int32 { Musl.shutdown(fd, Int32(how)) }
    #endif
}
