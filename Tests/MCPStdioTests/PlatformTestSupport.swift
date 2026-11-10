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

/// Test host only: installs a no-op handler without SA_RESTART and returns a restore action.
/// Darwin uses sigaction(2) with no flags. On Linux `signal(2)` suffices because poll(2) is
/// never restarted after a handler there; it always fails with EINTR.
func installNoopSignalHandler(_ number: Int32) throws -> () -> Void {
    #if canImport(Darwin)
    var action = sigaction(), old = sigaction()
    action.__sigaction_u.__sa_handler = { _ in }
    sigemptyset(&action.sa_mask); action.sa_flags = 0
    guard sigaction(number, &action, &old) == 0 else { throw Errno(rawValue: errno) }
    return { var previous = old; _ = sigaction(number, &previous, nil) }
    #else
    // A failed installation shows up as missing interruptions in the calling test.
    let previous = signal(number, { _ in })
    return { _ = signal(number, previous) }
    #endif
}

/// `pthread_t` for a recorded thread identity: a pointer on Darwin and musl, an integer on Glibc.
func threadHandle(_ identity: UInt) -> pthread_t {
    #if canImport(Glibc)
    return pthread_t(identity)
    #else
    return pthread_t(bitPattern: identity)!
    #endif
}
