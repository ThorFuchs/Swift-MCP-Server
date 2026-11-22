# Architecture

One SwiftPM GUI product, ResearchExplorerApp, wraps the same ExplorerService
and four ExplorerTools registrations as the unchanged CLI. Exactly three sidebar
destinations use one NavigationSplitView. No UI or Wikipedia semantics enter the SDK.
The system draws sidebar/toolbar materials; no generated mockup chrome is copied.

AppLifetime is MainActor/Observation state. AppResources loads finite fixtures off
the UI actor. ResearchController owns one driver, one worker and one latest pending
action. Supersession increments a generation, cancels and joins old work, and checks
the full snapshot/part identity before publication. Section and reference loading
are distinct, and absent/expired data offers explicit new-outline recovery.
No silent revision refresh, HTML renderer, thumbnail fetch or live fallback exists.

The app owns one ActivityStore and ServerController across window navigation/close.
Explicit Start constructs an SDKHTTPHost, then the real public Server/HTTPTransport/
ServerService graph. Stop/Restart retain and join that run. Quit uses a narrow
NSApplicationDelegate asynchronous reply. A bounded UI shutdown wait declines Quit
on debt while retaining the real run/transition; it never manufactures a join.
The public SDK still requires cancellation-cooperative components; no preemptive
process termination or new interpretation of FIN/TLS is introduced.

ToolActivityObserver wraps each actual catalogue handler once, propagates failures,
and observes the returned isError flag. The nil default preserves CLI behavior.
It stores no arguments, bodies, headers, provider descriptions or credentials.
Pre-handler wire/schema rejections are outside this facade; connections are shown
as unavailable. Tool counters are explicitly eligible-handler metrics, not an
exhaustive HTTP request/connection/session claim. Local Research never enters them.

The Research view can use live Wikipedia (enwiki) or the fictional Riverglass collection,
labelled Offline demo. Live errors never fall back to fictional content.

## Real MCP clients (RE-02)

`MCPResearchClient` (ExplorerMCP) adapts the public SDK `Client` to the same `ResearchClient`
operations as `ExplorerService`. `prepare()` runs `server/discover` and every `tools/list` page and
requires all four tools with an `outputSchema`, so the SDK validates each `structuredContent` before
the adapter sees it; calls before `prepare()` fail with `notPrepared` and send nothing. The adapter
then decodes the `{status, value | problem}` envelope strictly and checks that each result names the
snapshot and part that was asked for. Tool problems are rethrown as the owned `ExplorerProblem`
(re-derived from the code, never server text); JSON-RPC rejections, invalid responses, identity
mismatches and transport failures are separate `MCPResearchFailure` cases.

- **App, HTTP:** Server → *Explore MCP* is enabled only while this app's server runs. One
  `MCPJourneyController` task uses `HTTPClientTransport` against the announced loopback endpoint and
  records a finite (≤ 8 steps) metadata-only timeline. Stop cancels the journey first; Quit and a
  source switch cancel and join it. The tool calls reach Activity through the existing handler
  observer only; the journey adds no events of its own.
- **CLI, stdio:** `research-explorer --mcp-client` launches itself as `--stdio` with
  `StdioClientTransport`, runs the same journey, closes the child's input and joins `run()`; on
  failure it cancels the run (SIGTERM, SIGKILL after 2 s) and joins. `--walkthrough` stays the
  in-process path and says *DIRECT (not MCP)*.
