# stdio transport

MCPStdio runs one modern MCP2026-07-28 connection over pipes or stream sockets.
The host supplies a Server, a VerifiedPrincipal, an origin and the descriptors,
and owns the run task. The library starts no subprocess, installs no signal
handler and bootstraps no logger. The synthetic executable in Tools/StdioFixture
is the native subprocess/public-product consumer; it writes diagnostics to stderr.

LineFramer incrementally enforces byte/chunk limits before growing storage,
accepts LF and CRLF, and rejects empty lines, malformed UTF-8, oversize frames and
nonempty unterminated EOF. JSON's compact writer escapes payload newlines. Every
output is exactly one complete encoded envelope followed by LF. Concurrent
requests can finish out of order; one serial writer prevents frame interleaving.
A failed partial write poisons the connection: an incomplete prefix may already
be in the pipe, but no subsequent frame is appended to it.

Swift System supplies descriptor vocabulary and checked syscall results. Each
connection has two owned worker threads, each with one pending operation and a
private nonblocking wake pipe. Descriptor duplication and nonblocking syscalls
happen at the ownership boundary; poll/read/write run on those workers rather than
Swift cooperative executors. Cancellation wakes poll, and run awaits both worker
loops and all structured request tasks before returning. EINTR/EAGAIN retry within
the original finite deadline; close is never retried after EINTR. Only pipes and
stream sockets with no blocking SO_LINGER close are accepted.

Owned descriptors transfer only after successful construction. The transport
makes close-on-exec duplicates, sets nonblocking mode and output F_SETNOSIGPIPE,
then closes the transferred originals. The host must transfer exclusive I/O and
flag control, including any aliases of their underlying file descriptions.
Borrowed descriptors must already be nonblocking, and borrowed output must have
F_GETNOSIGPIPE enabled by the host. The transport closes only its duplicates and
never changes host flags. The host keeps those flags and sole read/write ownership
stable until run finishes; concurrent alias I/O or flag mutation violates the
borrowed contract. Darwin's no-SIGPIPE flag is shared by duplicates; this
requirement avoids installing process-global signal handlers or silently changing
borrowed host state. Construction rejection leaves host descriptors intact.
See [Apple's fcntl implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_descrip.c).

StdioPolicy has independent finite frame, chunk, worker, ingress queue and writer
count/byte limits, idle/incomplete-frame/write deadlines, and a bounded drain.
Ingress reservations use the admitted parser report's logical retained weight,
not merely the input byte count. Writer reservations include both waiting and
in-flight frames before a second framed copy is made. Limits reject overload;
they do not grow queues or reset accounts. Configure writerBytes and core result
limits consistently; the default writer budget is1MiB even though the core can
validate a larger result. Reported weights are logical bounds, not a measured RSS
or wall-clock guarantee.

Server.inspectIngress uses separate bounded control admission and returns either
a silent notification or a single-use AdmittedIngress. Its parser report, input
bytes, principal/origin, exact-ID correlation, deadline and cumulative RequestBudget
continue into dispatch unchanged. A foreign server or a second consumption cannot
execute it. Dropped queued admissions terminate their accounts. Control routing
continues while request workers are occupied; valid cancellation matches only
currently queued/active typed IDs in that principal/origin, with no unknown-ID
memoization. Recognizable malformed/unsupported notifications still attempt zero
responses, while genuine malformed requests retain D01. Transport admission,
framing, I/O and dispatch ownership remain server-owned rather than JSON work.

EOF or shutdown stops new input and drains already accepted requests. Only this
principal/origin's subscriptions close. D02's real stdio sequence is acknowledgement,
accepted events, cancellation notification, then complete response for server close;
client cancellation sends no terminal frame. Other requests can interleave between
whole frames on shared stdout. Drain expiry or run-task cancellation aborts both
I/O directions, cancels producers and awaits cleanup. Provider callbacks must
cooperate with cancellation: a callback that ignores it delays joining beyond the
drain trigger. The SDK cannot terminate arbitrary Swift code or host processes.

Native Swift Testing cases use owned subprocesses and real pipes/socket half-close
for fragmentation/coalescing, exact numeric IDs, concurrent responses, notification
silence, cancellation under saturation/queueing, progress/subscription ordering,
invalid framing, stalled/broken stdout, EOF, overflow, ownership and descriptor
leaks. The test host may kill only children it created. The detailed current
receipt and recorded limitations are in Docs/Evidence/Stdio/summary.json after
qualification. HTTP/TLS, ServiceLifecycle/observability, referee, physical-memory
calibration and DocC compilation retain their own later gates.
