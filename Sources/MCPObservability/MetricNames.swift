// SPDX-License-Identifier: Apache-2.0
public enum MetricNames {
    public static let started = "mcp.requests.started"
    public static let finished = "mcp.requests.finished"
    public static let duration = "mcp.request.duration"
    public static let activeScopes = "mcp.diagnostics.active"
    public static let handlers = "mcp.handlers.active"
    public static let subscriptions = "mcp.subscriptions.active"
    public static let bufferedBytes = "mcp.buffers.bytes"
    public static let eventBytes = "mcp.events.bytes"
}
