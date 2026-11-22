# What Research Explorer's MCP client and server exchange

Protocol: **MCP 2026-07-28**, stateless. Every request is self-contained: the protocol version and
client capabilities travel in `params._meta` (`io.modelcontextprotocol/protocolVersion`,
`io.modelcontextprotocol/clientCapabilities`). There is no `initialize` handshake, no session ID,
no GET event stream and no replay.

## The journey (Server → Explore MCP, or `research-explorer --mcp-client`)

| Step | JSON-RPC method | HTTP headers (Streamable HTTP) | What the client checks |
| --- | --- | --- | --- |
| 1 | `server/discover` | `MCP-Protocol-Version`, `Mcp-Method` | 2026-07-28 is offered |
| 2 | `tools/list` (all pages) | same | all four tools present, each with an `outputSchema` |
| 3 | `tools/call` `search_articles` | + `Mcp-Name: search_articles` | outputSchema, `{status, value}` envelope, provider and project |
| 4 | `tools/call` `get_article_outline` | + `Mcp-Name` | outputSchema, snapshot identity admitted by the source profile |
| 5 | `tools/call` `read_article_section` | + `Mcp-Name` | outputSchema, same snapshot and part as requested |
| 6 | `tools/call` `get_section_references` | + `Mcp-Name` | outputSchema, same snapshot as requested |

Over stdio the same JSON-RPC messages travel as newline-delimited frames on the child's standard
input/output; the server writes nothing else to stdout.

Failures stay distinct: a tool's domain problem (`isError` with `{status: "error", problem}`, e.g.
`absent_snapshot` after the 300 s expiry) is a typed `ExplorerProblem`; a JSON-RPC error is
`rejected(code)`; a response failing protocol or outputSchema validation is `invalidResponse`; a
schema-valid result for another snapshot or part is `identityMismatch`; refused connections,
closed streams and deadlines are `transport`.

## Lifecycle and ownership

- The app never starts the server or a client on its own. *Explore MCP* is enabled only while this
  app's server is running and uses its announced loopback endpoint.
- One journey is one owned task. **Stop** cancels it before stopping the server (the server's drain
  closes any remaining exchange). **Quit** and **source switching** cancel *and join* it and discard
  its results; a source switch is refused while a journey runs. Starting the server again begins
  with an empty journey.
- The stdio client owns its child: it closes the child's input and joins `run()`; on failure it
  cancels the run (SIGTERM, then SIGKILL after 2 s) and joins.

## What is observed, and what is not

- **Exchange inspector** (opt-in per run, *Record exchange details*): a wrapper around the real SDK
  transport records, per exchange, the method, the tool name (only for the four catalogue tools),
  bytes sent, bytes and messages received, outcome and duration. At most 32 records; overflow is
  counted, not kept. In memory only, never exported; cleared on a new run, server start, source switch
  and quit. No body, argument, header value, URL or error text.
- **Activity** counts this app's tool-handler invocations from any client: an external client, a
  copied recipe or *Explore MCP* (the handler cannot tell them apart, so it does not claim to).
  Local Research calls the service directly and is recorded separately as *Local research*.
  Pre-handler transport or schema rejections and HTTP connections are not observed. Events and the
  export are bounded, redacted projections (`payloadRecorded: false`).

## Connection recipes

Server → *Connection details* shows `curl` commands for `server/discover`, `tools/list` and
`tools/call search_articles` against the running endpoint. `InspectorAndRecipeTests` executes the
same recipe model against a live host and checks that the recipe bodies equal what the SDK's
`Client` sends (apart from the request ID). A Swift client uses `Client` with
`HTTPClientTransport(endpoint:)` from Swift-MCP-Server-HTTP.

The listener is **anonymous loopback development access** only (Host checked, browser Origins and
`Authorization` rejected). It is not a protected resource server.
