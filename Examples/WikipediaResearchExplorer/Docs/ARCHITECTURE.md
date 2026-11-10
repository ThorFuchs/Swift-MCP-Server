# Architecture

One SwiftPM GUI product, WikipediaResearchExplorerApp, wraps the same ExplorerService
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
