// SPDX-License-Identifier: Apache-2.0
// JSON Schemas for the Tasks extension (io.modelcontextprotocol/tasks, revision 2026-07-28).
// Original transcription of the shapes defined in
// https://github.com/modelcontextprotocol/ext-tasks (specification/2026-07-28/tasks.md).
import JSON
import MCPProtocol

enum TaskSchemas {
    static let identifier = "io.modelcontextprotocol/tasks"

    static let task = #"""
    {"type":"object","required":["taskId","status","createdAt","lastUpdatedAt","ttlMs"],
     "properties":{
       "taskId":{"type":"string","minLength":1},
       "status":{"enum":["working","input_required","completed","cancelled","failed"]},
       "statusMessage":{"type":"string"},
       "createdAt":{"type":"string"},
       "lastUpdatedAt":{"type":"string"},
       "ttlMs":{"type":["integer","null"],"minimum":0},
       "pollIntervalMs":{"type":"integer","minimum":0}}}
    """#

    static let settings = #"{"type":"object"}"#
    static let taskIdParameters = #"""
    {"type":"object","required":["taskId"],"properties":{"taskId":{"type":"string","minLength":1,"maxLength":256}}}
    """#
    static let updateParameters = #"""
    {"type":"object","required":["taskId","inputResponses"],
     "properties":{"taskId":{"type":"string","minLength":1,"maxLength":256},"inputResponses":{"type":"object","maxProperties":64}}}
    """#
    /// `CreateTaskResult = Result & Task`: the task fields sit at the top level next to
    /// `resultType` (the registry adds the `resultType: "task"` constant).
    static let createResult = task
    /// `GetTaskResult`: a `DetailedTask` plus `resultType: "complete"`.
    static let getResult = #"""
    {"allOf":[\#(task),
      {"type":"object","required":["resultType"],"properties":{
        "resultType":{"const":"complete"},
        "result":{"type":"object"},
        "error":{"type":"object","required":["code","message"]},
        "inputRequests":{"type":"object"}}}]}
    """#
    /// `notifications/tasks` params: `NotificationParams & DetailedTask` (no `resultType`).
    static let notification = #"""
    {"allOf":[\#(task),
      {"type":"object","properties":{
        "_meta":{"type":"object"},
        "result":{"type":"object"},
        "error":{"type":"object","required":["code","message"]},
        "inputRequests":{"type":"object"}},
       "not":{"required":["resultType"]}}]}
    """#
    /// `UpdateTaskResult` / `CancelTaskResult`: empty acknowledgement.
    static let acknowledgement = #"{"type":"object","required":["resultType"],"properties":{"resultType":{"const":"complete"}}}"#

    static func parse(_ text: String) throws -> JSON {
        try WireCodec.parse(Array(text.utf8), limits: .balanced).result
    }
}
