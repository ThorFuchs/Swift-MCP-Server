# Native stdio fixture and public consumer

This synthetic executable imports production MCPStdio, MCPServer and MCPProtocol
with the pinned public JSON and Swift System products. It is a test host rather
than a reusable library; it explicitly sets its own SIGPIPE disposition and
writes READY/provider/cleanup diagnostics only to stderr. No application corpus,
credentials or global logger bootstrap is used.

Its modes exercise echo/exact IDs, cancellation, progress, subscription EOF,
oversize/malformed input, stalled/broken output, queue limits and finite drain.
The frozen protocol metadata is required on every request. This fixture is
separate from the official conformance everything-server/referee fixture.

The outside-root default-backend consumer is built by:

```sh
python3 Scripts/stdio_probe.py external -- python3 Scripts/stdio_consumer.py
```

Run the native Swift Testing integration with its actual executable selected:

```sh
MCP_STDIO_FIXTURE=/absolute/path/to/StdioFixture python3 Scripts/stdio_probe.py --testing native -- swift test --package-path Tools/JSONIntegration --scratch-path .build/reproduce --disable-sandbox --jobs 4
```

The probe records the selected fixture path/hash and actual Testing discovery
paths, generated resource staging, native environment, input bytes, logs and
exit results. Published package settings contain no unsafe flags. A successful
three-SDK-product stdio build does not qualify the full eight-product consumer.
