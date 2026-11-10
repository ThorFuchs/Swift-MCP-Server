# ``MCPStdio``

Serve newline-framed modern MCP through caller-supplied pipes or stream sockets.

``StdioTransport`` validates descriptors at construction and starts I/O only in its
caller-owned run lifetime. ``DescriptorOwnership`` distinguishes transferred originals
from borrowed descriptors. Borrowed handles must already be nonblocking and suppress
SIGPIPE; transport-owned duplicates close independently. Fixed workers, private wake
pipes and cancellation join their owned operations. The library installs no signals.

``StdioPolicy`` has independent finite framing, queue, writer, byte and time ceilings.
Recognizable notifications are silent; genuine invalid envelopes keep their dated
errors. One bounded writer serializes complete frames. Shutdown stops input and drains
admitted work; cancellation aborts owned I/O and joins workers. A host awaits run before
releasing providers. Late peer EOF visibility is an I/O observation, not descriptor
ownership inferred from a recycled integer.

The full consumer transfers two pipe ends, keeps its peer ends actor-isolated, exchanges
an exact-ID response and checks EOF after joined lifecycle shutdown. Protocol stdout
contains frames only. The 202-function native SDK baseline includes real subprocess,
backpressure, cancellation and ownership cases.

## Topics

### Owned connection
- ``StdioTransport``
- ``StdioPolicy``
- ``DescriptorOwnership``
- ``StdioFailure``


## Construction, activation and settlement

The synchronous initializer prepares two duplicated endpoints and their private
wake pipes without activating transport workers. Owned originals transfer only
after preparation and flag setup succeed. A rejected constructor leaves originals
with the caller and attempts each prepared close and permitted flag restoration.
Borrowed originals and flags remain caller-owned. Successful transfer attempts
each original close once; ambiguous close is recorded and never retried.

The single caller-owned `run` activates at most two workers. Cancellation and
partial activation settle both endpoints independently. A never-started endpoint
needs no worker-exit event. Shutdown before run closes dormant preparation; the
first run then completes without activation. Never-run destruction owns only
prepared resources. Shutdown during a run retains the existing accepted-work drain.
Both endpoint joins are attempted even if one reports failure. Worker-loop exit
acknowledgement is distinct from descriptor-close success and OS thread inspection.

Ordinary failures retain their existing type when cleanup succeeds. When cleanup
also reports failure, ``StdioLifecycleFailure`` retains the operation separately
from at most sixteen ordered ``StdioLifecycleIssue`` values. A nil operation means
the operation completed but cleanup failed. No ambiguous close is retried.

These D28 changes and ten Swift Testing functions are SOURCE_IMPLEMENTED_NATIVE_NOT_RUN.
Their compatibility, races and lifecycle observations still require admitted native
compilation/testing. Historical baseline passes do not qualify these new bytes.
The internal direct-endpoint test helper retains its prior eager default; the
public transport explicitly selects deferred activation on both endpoints.
