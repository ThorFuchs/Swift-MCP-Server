# ``MCPObservability``

Inject bounded diagnostics without changing wire authority or work accounting.

Pass ``RequestInstrumentation`` to the core with a host-owned Logger and MetricsFactory.
It never bootstraps global systems or chooses an exporter. ``DiagnosticTrace`` carries
verified typed identity through structured calls in a fresh ServiceContext. Inherited
baggage and logger metadata/providers are excluded. ``RedactionPolicy`` records fixed
method/transport/outcome categories and optional nonsecret bounded correlation.
Credentials, principals, payloads, state, private URIs, IDs and error descriptions stay
out of log fields and metric dimensions.

Fixed buckets bound the cache at665instruments, including five gauges. Active scopes
default to1024 and have a hard4096ceiling. Durations saturate safely. Sampling measures
logical core activity, not RSS or throughput. Wire protocol logging is a separate opt-in.

After joined request owners, close instrumentation. Active closure is rejected; successful
closure destroys each injected instrument once. The core enforces one observer callback
and retains budget/permit/terminal ownership. The full consumer verifies three isolated
transport contexts, three completions and no active instruments after joined shutdown.

## Topics

### Injected instrumentation
- ``RequestInstrumentation``
- ``DiagnosticTrace``
- ``DiagnosticCorrelation``
- ``RedactionPolicy``

## Provisional request trace propagation

Hosts may explicitly use RequestTraceScope.withTrace inside an admitted provider
or host integration closure. The scope carries only already validated request trace
fields through structured child tasks and restores the prior task-local context on
exit. Other host-provided ServiceContext entries remain present; host privacy policy
still governs them. It neither starts an exporter nor adds trace fields to metrics or logs. A
request with no trace clears inherited trace within that scope. Treat baggage as
untrusted and potentially sensitive. This API is provisional pending native and
independent-consumer qualification.
