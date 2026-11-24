# Child process ownership

Keep exchange completion, stream cleanup and OS process termination distinct.

## Own the run

Create the transport without starting a child. The host runs `run()` in a structured task and waits for the server to become usable using its own readiness strategy. All requests share that child; cancellation of a call removes its route, while cancellation of the run initiates child teardown.

Use `shutdown()` to close stdin for graceful termination. It does not promise that an uncooperative server exits immediately. Retain and await the run task; the host can cancel it when necessary under its own lifecycle policy.

## Settle streams and status

When stdout ends, no additional protocol response can be produced. Pending requests fail with `serverExited`, and stdin is finished. The transport keeps the stderr reader alive for legitimate final diagnostics. It retains the run permit until the child and its owned stream tasks are joined.

A successful return from `run()` represents successful child termination. Nonzero and signal exits carry the exact Subprocess termination status through `unsuccessfulTermination`. Caller cancellation takes precedence as `CancellationError`; primary I/O/framing errors propagate.

Do not install global signal handlers in a library consumer to hide a child-exit error. The host owns its executable trust boundary and may decide how to handle stderr, which can contain private data.

The Core #53 integrated native receipt recorded 28 of 28 regular CLEAN fixtures with exit 0 after the correction. That historical receipt does not establish every abnormal or uncooperative process path.
