# MCP Apps (`MCPApps`)

`MCPApps` helps servers offer interactive HTML views through the MCP Apps extension
(`io.modelcontextprotocol/ui`, SEP-1865, stable 2026-01-26). A view is a `ui://` resource
with MIME type `text/html;profile=mcp-app`; a tool points at it with `_meta.ui.resourceUri`.
Hosts that render apps show the view; every other host uses the tool's text result.

## Setup

```swift
let dashboard = try AppView(uri: "ui://weather/dashboard", name: "dashboard", html: dashboardHTML,
    metadata: AppViewMetadata(csp: AppContentSecurityPolicy(connectDomains: ["https://api.weather.example"]),
                              prefersBorder: true))
let forecast = ToolRegistration(definition: try dashboard.annotate(forecastDefinition)) { arguments, context in
    // Always return meaningful content; add structuredContent for the view.
    try forecastResult(arguments, forView: MCPApps.clientRendersApps(context))
}
let tools = [forecast], resources = [try dashboard.resource()]
try MCPApps.validate(tools: tools, resources: resources)       // every referenced view is served
let server = try await Server.make(info: info,
    catalog: ServerCatalog(tools: tools, resources: resources, extensions: [try MCPApps.registration()]), cursors: cursors)
```

## Behavior

- **Views.** `AppView` checks the URI (`ui://<server>/<path>`, no query or fragment), a
  non-empty name and HTML, and that every CSP entry is an `http(s)` or `ws(s)` origin (a
  leading `*.` host wildcard is allowed). `resource()` serves the HTML as `text` with the
  same `_meta.ui` on the resource and on its contents.
- **Metadata.** `_meta.ui.csp` (`connectDomains`, `resourceDomains`, `frameDomains`,
  `baseUriDomains`; empty lists are omitted), `permissions` (`camera`, `microphone`,
  `geolocation`, `clipboardWrite`), `domain` and `prefersBorder`.
- **Tools.** `annotate` adds `_meta.ui.resourceUri` and, unless it is both, `visibility`
  (`["model"]` or `["app"]`), keeping other `_meta` members. The deprecated
  `_meta["ui/resourceUri"]` key is not written.
- **Capability.** `clientRendersApps(_:)` is true when the request's client capabilities
  declare the extension with `text/html;profile=mcp-app` in `mimeTypes`. `registration()`
  optionally advertises the extension in `server/discover`.
- **Validation.** `validate(tools:resources:)` rejects a tool whose `resourceUri` is not a
  served `ui://` resource with the MCP Apps MIME type.

## Not yet implemented

- Hiding app-only views from `resources/list`, and tool lists that differ by host capability.
- The host side (`ui/*` messages between view and host) belongs to clients that render views.
