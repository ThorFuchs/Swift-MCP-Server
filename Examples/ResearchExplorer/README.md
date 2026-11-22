# Research Explorer

A complete example built on Swift-MCP-Server: an MCP server that lets an assistant research
Wikipedia articles with four bounded, read-only tools, plus a native macOS app that hosts the
same server over HTTP and shows its activity.

| Tool | What it does |
|---|---|
| `search_articles` | Finds candidate articles |
| `get_article_outline` | Pins one article **revision** and returns its sections |
| `read_article_section` | Reads one section of that pinned revision as plain text |
| `get_section_references` | Returns the references cited in that section |

An outline binds one immutable revision snapshot; later section and reference reads use exactly
that snapshot, so an assistant never mixes text from different revisions. Revision, permalink,
retrieval time and license stay visible. Expired snapshots are reported, never silently replaced.

## Run

Requirements: macOS 27, Swift 6.4.

```bash
# MCP over stdio (offline Riverglass fixtures), e.g. for a local assistant
swift run --package-path Examples/ResearchExplorer research-explorer --stdio

# A real MCP client: launches `research-explorer --stdio` as a child and calls all four tools
swift run --package-path Examples/ResearchExplorer research-explorer --mcp-client

# Human-readable walkthrough of the same four tools, called directly (not over MCP)
swift run --package-path Examples/ResearchExplorer research-explorer --walkthrough

# macOS app: Research / Server / Activity, Offline demo (default) or live Wikipedia (enwiki)
swift run --package-path Examples/ResearchExplorer ResearchExplorerApp
```

The app starts with zero network requests and opens on the **Offline demo**: five fictional
Riverglass articles with sections, references and two revisions of one article. **Explore the
offline collection** runs a one-click tour; **Check for a newer revision** compares a pinned revision
with the latest one explicitly. See [the Riverglass collection](Docs/OFFLINE_COLLECTION.md).
Wikipedia English is chosen explicitly in **Server**, which also starts a loopback Streamable HTTP
MCP endpoint (via Swift-MCP-Server-HTTP) serving the same four tools; **Activity** shows per-tool
counters. Riverglass content is original fictional teaching data, not Wikimedia responses.

The example resolves Swift-MCP-Server and Swift-MCP-Server-HTTP by URL (`main` until 1.0),
because the HTTP package depends on the core by URL as well.

## What it demonstrates

- Typed tool registrations with input/output schemas and bounded, structured results
- The stdio transport (`MCPStdio`) and the HTTP transport (`MCPHTTP`) serving one service
- Real clients of both: `Client` + `HTTPClientTransport` (Server → *Explore MCP*) and `Client` + `StdioClientTransport` (`--mcp-client`), with outputSchema-validated, identity-checked results
- Owned lifetimes: explicit start/stop, cancellation and joined shutdown, no global side effects
- Bounded live I/O: deadlines, limited retries, size caps, no cookies, credentials or redirect escapes

Design notes: [Architecture](Docs/ARCHITECTURE.md) · [Live Wikipedia contract](Docs/LIVE_CONTRACT.md) · [Riverglass offline collection](Docs/OFFLINE_COLLECTION.md).

## Tests

```bash
Examples/ResearchExplorer/Scripts/test.sh
```

builds the CLI and runs all tests, including an end-to-end stdio journey against the real
executable.

## License

Apache-2.0 for the example's code and fictional fixtures. Wikipedia content keeps its own
license and attribution. Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
