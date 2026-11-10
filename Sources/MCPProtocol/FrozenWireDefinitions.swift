// SPDX-License-Identifier: Apache-2.0
// Generated names from frozen c518f7a927cff918bce35d3522fcdb046d264d7c; no schema engine.
public enum FrozenWireDefinition: String, Sendable, CaseIterable {
    case Annotations
    case AudioContent
    case BaseMetadata
    case BlobResourceContents
    case BooleanSchema
    case CacheableResult
    case CallToolRequest
    case CallToolRequestParams
    case CallToolResult
    case CallToolResultResponse
    case CancelledNotification
    case CancelledNotificationParams
    case ClientCapabilities
    case ClientNotification
    case ClientRequest
    case ClientResult
    case CompleteRequest
    case CompleteRequestParams
    case CompleteResult
    case CompleteResultResponse
    case ContentBlock
    case CreateMessageRequest
    case CreateMessageRequestParams
    case CreateMessageResult
    case Cursor
    case DiscoverRequest
    case DiscoverResult
    case DiscoverResultResponse
    case ElicitRequest
    case ElicitRequestFormParams
    case ElicitRequestParams
    case ElicitRequestURLParams
    case ElicitResult
    case EmbeddedResource
    case EmptyResult
    case EnumSchema
    case Error
    case GetPromptRequest
    case GetPromptRequestParams
    case GetPromptResult
    case GetPromptResultResponse
    case HeaderMismatchError
    case Icon
    case Icons
    case ImageContent
    case Implementation
    case InputRequest
    case InputRequests
    case InputRequiredResult
    case InputResponse
    case InputResponseRequestParams
    case InputResponses
    case InternalError
    case InvalidParamsError
    case InvalidRequestError
    case JSONArray
    case JSONObject
    case JSONRPCErrorResponse
    case JSONRPCMessage
    case JSONRPCNotification
    case JSONRPCRequest
    case JSONRPCResponse
    case JSONRPCResultResponse
    case JSONValue
    case LegacyTitledEnumSchema
    case ListPromptsRequest
    case ListPromptsResult
    case ListPromptsResultResponse
    case ListResourceTemplatesRequest
    case ListResourceTemplatesResult
    case ListResourceTemplatesResultResponse
    case ListResourcesRequest
    case ListResourcesResult
    case ListResourcesResultResponse
    case ListRootsRequest
    case ListRootsResult
    case ListToolsRequest
    case ListToolsResult
    case ListToolsResultResponse
    case LoggingLevel
    case LoggingMessageNotification
    case LoggingMessageNotificationParams
    case MetaObject
    case MethodNotFoundError
    case MissingRequiredClientCapabilityError
    case ModelHint
    case ModelPreferences
    case MultiSelectEnumSchema
    case Notification
    case NotificationMetaObject
    case NotificationParams
    case NumberSchema
    case PaginatedRequest
    case PaginatedRequestParams
    case PaginatedResult
    case ParseError
    case PrimitiveSchemaDefinition
    case ProgressNotification
    case ProgressNotificationParams
    case ProgressToken
    case Prompt
    case PromptArgument
    case PromptListChangedNotification
    case PromptMessage
    case PromptReference
    case ReadResourceRequest
    case ReadResourceRequestParams
    case ReadResourceResult
    case ReadResourceResultResponse
    case Request
    case RequestId
    case RequestMetaObject
    case RequestParams
    case Resource
    case ResourceContents
    case ResourceLink
    case ResourceListChangedNotification
    case ResourceRequestParams
    case ResourceTemplate
    case ResourceTemplateReference
    case ResourceUpdatedNotification
    case ResourceUpdatedNotificationParams
    case Result
    case ResultMetaObject
    case ResultType
    case Role
    case Root
    case SamplingMessage
    case SamplingMessageContentBlock
    case ServerCapabilities
    case ServerNotification
    case ServerResult
    case SingleSelectEnumSchema
    case StringSchema
    case SubscriptionFilter
    case SubscriptionsAcknowledgedNotification
    case SubscriptionsAcknowledgedNotificationParams
    case SubscriptionsListenRequest
    case SubscriptionsListenRequestParams
    case SubscriptionsListenResult
    case SubscriptionsListenResultMetaObject
    case SubscriptionsListenResultResponse
    case TextContent
    case TextResourceContents
    case TitledMultiSelectEnumSchema
    case TitledSingleSelectEnumSchema
    case Tool
    case ToolAnnotations
    case ToolChoice
    case ToolListChangedNotification
    case ToolResultContent
    case ToolUseContent
    case UnsupportedProtocolVersionError
    case UntitledMultiSelectEnumSchema
    case UntitledSingleSelectEnumSchema
}
public enum WireShapes {
    public enum Annotations: WireShape { public static let definition = FrozenWireDefinition.Annotations }
    public enum AudioContent: WireShape { public static let definition = FrozenWireDefinition.AudioContent }
    public enum BaseMetadata: WireShape { public static let definition = FrozenWireDefinition.BaseMetadata }
    public enum BlobResourceContents: WireShape { public static let definition = FrozenWireDefinition.BlobResourceContents }
    public enum BooleanSchema: WireShape { public static let definition = FrozenWireDefinition.BooleanSchema }
    public enum CacheableResult: WireShape { public static let definition = FrozenWireDefinition.CacheableResult }
    public enum CallToolRequest: WireShape { public static let definition = FrozenWireDefinition.CallToolRequest }
    public enum CallToolRequestParams: WireShape { public static let definition = FrozenWireDefinition.CallToolRequestParams }
    public enum CallToolResult: WireShape { public static let definition = FrozenWireDefinition.CallToolResult }
    public enum CallToolResultResponse: WireShape { public static let definition = FrozenWireDefinition.CallToolResultResponse }
    public enum CancelledNotification: WireShape { public static let definition = FrozenWireDefinition.CancelledNotification }
    public enum CancelledNotificationParams: WireShape { public static let definition = FrozenWireDefinition.CancelledNotificationParams }
    public enum ClientCapabilities: WireShape { public static let definition = FrozenWireDefinition.ClientCapabilities }
    public enum ClientNotification: WireShape { public static let definition = FrozenWireDefinition.ClientNotification }
    public enum ClientRequest: WireShape { public static let definition = FrozenWireDefinition.ClientRequest }
    public enum ClientResult: WireShape { public static let definition = FrozenWireDefinition.ClientResult }
    public enum CompleteRequest: WireShape { public static let definition = FrozenWireDefinition.CompleteRequest }
    public enum CompleteRequestParams: WireShape { public static let definition = FrozenWireDefinition.CompleteRequestParams }
    public enum CompleteResult: WireShape { public static let definition = FrozenWireDefinition.CompleteResult }
    public enum CompleteResultResponse: WireShape { public static let definition = FrozenWireDefinition.CompleteResultResponse }
    public enum ContentBlock: WireShape { public static let definition = FrozenWireDefinition.ContentBlock }
    public enum CreateMessageRequest: WireShape { public static let definition = FrozenWireDefinition.CreateMessageRequest }
    public enum CreateMessageRequestParams: WireShape { public static let definition = FrozenWireDefinition.CreateMessageRequestParams }
    public enum CreateMessageResult: WireShape { public static let definition = FrozenWireDefinition.CreateMessageResult }
    public enum Cursor: WireShape { public static let definition = FrozenWireDefinition.Cursor }
    public enum DiscoverRequest: WireShape { public static let definition = FrozenWireDefinition.DiscoverRequest }
    public enum DiscoverResult: WireShape { public static let definition = FrozenWireDefinition.DiscoverResult }
    public enum DiscoverResultResponse: WireShape { public static let definition = FrozenWireDefinition.DiscoverResultResponse }
    public enum ElicitRequest: WireShape { public static let definition = FrozenWireDefinition.ElicitRequest }
    public enum ElicitRequestFormParams: WireShape { public static let definition = FrozenWireDefinition.ElicitRequestFormParams }
    public enum ElicitRequestParams: WireShape { public static let definition = FrozenWireDefinition.ElicitRequestParams }
    public enum ElicitRequestURLParams: WireShape { public static let definition = FrozenWireDefinition.ElicitRequestURLParams }
    public enum ElicitResult: WireShape { public static let definition = FrozenWireDefinition.ElicitResult }
    public enum EmbeddedResource: WireShape { public static let definition = FrozenWireDefinition.EmbeddedResource }
    public enum EmptyResult: WireShape { public static let definition = FrozenWireDefinition.EmptyResult }
    public enum EnumSchema: WireShape { public static let definition = FrozenWireDefinition.EnumSchema }
    public enum Error: WireShape { public static let definition = FrozenWireDefinition.Error }
    public enum GetPromptRequest: WireShape { public static let definition = FrozenWireDefinition.GetPromptRequest }
    public enum GetPromptRequestParams: WireShape { public static let definition = FrozenWireDefinition.GetPromptRequestParams }
    public enum GetPromptResult: WireShape { public static let definition = FrozenWireDefinition.GetPromptResult }
    public enum GetPromptResultResponse: WireShape { public static let definition = FrozenWireDefinition.GetPromptResultResponse }
    public enum HeaderMismatchError: WireShape { public static let definition = FrozenWireDefinition.HeaderMismatchError }
    public enum Icon: WireShape { public static let definition = FrozenWireDefinition.Icon }
    public enum Icons: WireShape { public static let definition = FrozenWireDefinition.Icons }
    public enum ImageContent: WireShape { public static let definition = FrozenWireDefinition.ImageContent }
    public enum Implementation: WireShape { public static let definition = FrozenWireDefinition.Implementation }
    public enum InputRequest: WireShape { public static let definition = FrozenWireDefinition.InputRequest }
    public enum InputRequests: WireShape { public static let definition = FrozenWireDefinition.InputRequests }
    public enum InputRequiredResult: WireShape { public static let definition = FrozenWireDefinition.InputRequiredResult }
    public enum InputResponse: WireShape { public static let definition = FrozenWireDefinition.InputResponse }
    public enum InputResponseRequestParams: WireShape { public static let definition = FrozenWireDefinition.InputResponseRequestParams }
    public enum InputResponses: WireShape { public static let definition = FrozenWireDefinition.InputResponses }
    public enum InternalError: WireShape { public static let definition = FrozenWireDefinition.InternalError }
    public enum InvalidParamsError: WireShape { public static let definition = FrozenWireDefinition.InvalidParamsError }
    public enum InvalidRequestError: WireShape { public static let definition = FrozenWireDefinition.InvalidRequestError }
    public enum JSONArray: WireShape { public static let definition = FrozenWireDefinition.JSONArray }
    public enum JSONObject: WireShape { public static let definition = FrozenWireDefinition.JSONObject }
    public enum JSONRPCErrorResponse: WireShape { public static let definition = FrozenWireDefinition.JSONRPCErrorResponse }
    public enum JSONRPCMessage: WireShape { public static let definition = FrozenWireDefinition.JSONRPCMessage }
    public enum JSONRPCNotification: WireShape { public static let definition = FrozenWireDefinition.JSONRPCNotification }
    public enum JSONRPCRequest: WireShape { public static let definition = FrozenWireDefinition.JSONRPCRequest }
    public enum JSONRPCResponse: WireShape { public static let definition = FrozenWireDefinition.JSONRPCResponse }
    public enum JSONRPCResultResponse: WireShape { public static let definition = FrozenWireDefinition.JSONRPCResultResponse }
    public enum JSONValue: WireShape { public static let definition = FrozenWireDefinition.JSONValue }
    public enum LegacyTitledEnumSchema: WireShape { public static let definition = FrozenWireDefinition.LegacyTitledEnumSchema }
    public enum ListPromptsRequest: WireShape { public static let definition = FrozenWireDefinition.ListPromptsRequest }
    public enum ListPromptsResult: WireShape { public static let definition = FrozenWireDefinition.ListPromptsResult }
    public enum ListPromptsResultResponse: WireShape { public static let definition = FrozenWireDefinition.ListPromptsResultResponse }
    public enum ListResourceTemplatesRequest: WireShape { public static let definition = FrozenWireDefinition.ListResourceTemplatesRequest }
    public enum ListResourceTemplatesResult: WireShape { public static let definition = FrozenWireDefinition.ListResourceTemplatesResult }
    public enum ListResourceTemplatesResultResponse: WireShape { public static let definition = FrozenWireDefinition.ListResourceTemplatesResultResponse }
    public enum ListResourcesRequest: WireShape { public static let definition = FrozenWireDefinition.ListResourcesRequest }
    public enum ListResourcesResult: WireShape { public static let definition = FrozenWireDefinition.ListResourcesResult }
    public enum ListResourcesResultResponse: WireShape { public static let definition = FrozenWireDefinition.ListResourcesResultResponse }
    public enum ListRootsRequest: WireShape { public static let definition = FrozenWireDefinition.ListRootsRequest }
    public enum ListRootsResult: WireShape { public static let definition = FrozenWireDefinition.ListRootsResult }
    public enum ListToolsRequest: WireShape { public static let definition = FrozenWireDefinition.ListToolsRequest }
    public enum ListToolsResult: WireShape { public static let definition = FrozenWireDefinition.ListToolsResult }
    public enum ListToolsResultResponse: WireShape { public static let definition = FrozenWireDefinition.ListToolsResultResponse }
    public enum LoggingLevel: WireShape { public static let definition = FrozenWireDefinition.LoggingLevel }
    public enum LoggingMessageNotification: WireShape { public static let definition = FrozenWireDefinition.LoggingMessageNotification }
    public enum LoggingMessageNotificationParams: WireShape { public static let definition = FrozenWireDefinition.LoggingMessageNotificationParams }
    public enum MetaObject: WireShape { public static let definition = FrozenWireDefinition.MetaObject }
    public enum MethodNotFoundError: WireShape { public static let definition = FrozenWireDefinition.MethodNotFoundError }
    public enum MissingRequiredClientCapabilityError: WireShape { public static let definition = FrozenWireDefinition.MissingRequiredClientCapabilityError }
    public enum ModelHint: WireShape { public static let definition = FrozenWireDefinition.ModelHint }
    public enum ModelPreferences: WireShape { public static let definition = FrozenWireDefinition.ModelPreferences }
    public enum MultiSelectEnumSchema: WireShape { public static let definition = FrozenWireDefinition.MultiSelectEnumSchema }
    public enum Notification: WireShape { public static let definition = FrozenWireDefinition.Notification }
    public enum NotificationMetaObject: WireShape { public static let definition = FrozenWireDefinition.NotificationMetaObject }
    public enum NotificationParams: WireShape { public static let definition = FrozenWireDefinition.NotificationParams }
    public enum NumberSchema: WireShape { public static let definition = FrozenWireDefinition.NumberSchema }
    public enum PaginatedRequest: WireShape { public static let definition = FrozenWireDefinition.PaginatedRequest }
    public enum PaginatedRequestParams: WireShape { public static let definition = FrozenWireDefinition.PaginatedRequestParams }
    public enum PaginatedResult: WireShape { public static let definition = FrozenWireDefinition.PaginatedResult }
    public enum ParseError: WireShape { public static let definition = FrozenWireDefinition.ParseError }
    public enum PrimitiveSchemaDefinition: WireShape { public static let definition = FrozenWireDefinition.PrimitiveSchemaDefinition }
    public enum ProgressNotification: WireShape { public static let definition = FrozenWireDefinition.ProgressNotification }
    public enum ProgressNotificationParams: WireShape { public static let definition = FrozenWireDefinition.ProgressNotificationParams }
    public enum ProgressToken: WireShape { public static let definition = FrozenWireDefinition.ProgressToken }
    public enum Prompt: WireShape { public static let definition = FrozenWireDefinition.Prompt }
    public enum PromptArgument: WireShape { public static let definition = FrozenWireDefinition.PromptArgument }
    public enum PromptListChangedNotification: WireShape { public static let definition = FrozenWireDefinition.PromptListChangedNotification }
    public enum PromptMessage: WireShape { public static let definition = FrozenWireDefinition.PromptMessage }
    public enum PromptReference: WireShape { public static let definition = FrozenWireDefinition.PromptReference }
    public enum ReadResourceRequest: WireShape { public static let definition = FrozenWireDefinition.ReadResourceRequest }
    public enum ReadResourceRequestParams: WireShape { public static let definition = FrozenWireDefinition.ReadResourceRequestParams }
    public enum ReadResourceResult: WireShape { public static let definition = FrozenWireDefinition.ReadResourceResult }
    public enum ReadResourceResultResponse: WireShape { public static let definition = FrozenWireDefinition.ReadResourceResultResponse }
    public enum Request: WireShape { public static let definition = FrozenWireDefinition.Request }
    public enum RequestId: WireShape { public static let definition = FrozenWireDefinition.RequestId }
    public enum RequestMetaObject: WireShape { public static let definition = FrozenWireDefinition.RequestMetaObject }
    public enum RequestParams: WireShape { public static let definition = FrozenWireDefinition.RequestParams }
    public enum Resource: WireShape { public static let definition = FrozenWireDefinition.Resource }
    public enum ResourceContents: WireShape { public static let definition = FrozenWireDefinition.ResourceContents }
    public enum ResourceLink: WireShape { public static let definition = FrozenWireDefinition.ResourceLink }
    public enum ResourceListChangedNotification: WireShape { public static let definition = FrozenWireDefinition.ResourceListChangedNotification }
    public enum ResourceRequestParams: WireShape { public static let definition = FrozenWireDefinition.ResourceRequestParams }
    public enum ResourceTemplate: WireShape { public static let definition = FrozenWireDefinition.ResourceTemplate }
    public enum ResourceTemplateReference: WireShape { public static let definition = FrozenWireDefinition.ResourceTemplateReference }
    public enum ResourceUpdatedNotification: WireShape { public static let definition = FrozenWireDefinition.ResourceUpdatedNotification }
    public enum ResourceUpdatedNotificationParams: WireShape { public static let definition = FrozenWireDefinition.ResourceUpdatedNotificationParams }
    public enum Result: WireShape { public static let definition = FrozenWireDefinition.Result }
    public enum ResultMetaObject: WireShape { public static let definition = FrozenWireDefinition.ResultMetaObject }
    public enum ResultType: WireShape { public static let definition = FrozenWireDefinition.ResultType }
    public enum Role: WireShape { public static let definition = FrozenWireDefinition.Role }
    public enum Root: WireShape { public static let definition = FrozenWireDefinition.Root }
    public enum SamplingMessage: WireShape { public static let definition = FrozenWireDefinition.SamplingMessage }
    public enum SamplingMessageContentBlock: WireShape { public static let definition = FrozenWireDefinition.SamplingMessageContentBlock }
    public enum ServerCapabilities: WireShape { public static let definition = FrozenWireDefinition.ServerCapabilities }
    public enum ServerNotification: WireShape { public static let definition = FrozenWireDefinition.ServerNotification }
    public enum ServerResult: WireShape { public static let definition = FrozenWireDefinition.ServerResult }
    public enum SingleSelectEnumSchema: WireShape { public static let definition = FrozenWireDefinition.SingleSelectEnumSchema }
    public enum StringSchema: WireShape { public static let definition = FrozenWireDefinition.StringSchema }
    public enum SubscriptionFilter: WireShape { public static let definition = FrozenWireDefinition.SubscriptionFilter }
    public enum SubscriptionsAcknowledgedNotification: WireShape { public static let definition = FrozenWireDefinition.SubscriptionsAcknowledgedNotification }
    public enum SubscriptionsAcknowledgedNotificationParams: WireShape { public static let definition = FrozenWireDefinition.SubscriptionsAcknowledgedNotificationParams }
    public enum SubscriptionsListenRequest: WireShape { public static let definition = FrozenWireDefinition.SubscriptionsListenRequest }
    public enum SubscriptionsListenRequestParams: WireShape { public static let definition = FrozenWireDefinition.SubscriptionsListenRequestParams }
    public enum SubscriptionsListenResult: WireShape { public static let definition = FrozenWireDefinition.SubscriptionsListenResult }
    public enum SubscriptionsListenResultMetaObject: WireShape { public static let definition = FrozenWireDefinition.SubscriptionsListenResultMetaObject }
    public enum SubscriptionsListenResultResponse: WireShape { public static let definition = FrozenWireDefinition.SubscriptionsListenResultResponse }
    public enum TextContent: WireShape { public static let definition = FrozenWireDefinition.TextContent }
    public enum TextResourceContents: WireShape { public static let definition = FrozenWireDefinition.TextResourceContents }
    public enum TitledMultiSelectEnumSchema: WireShape { public static let definition = FrozenWireDefinition.TitledMultiSelectEnumSchema }
    public enum TitledSingleSelectEnumSchema: WireShape { public static let definition = FrozenWireDefinition.TitledSingleSelectEnumSchema }
    public enum Tool: WireShape { public static let definition = FrozenWireDefinition.Tool }
    public enum ToolAnnotations: WireShape { public static let definition = FrozenWireDefinition.ToolAnnotations }
    public enum ToolChoice: WireShape { public static let definition = FrozenWireDefinition.ToolChoice }
    public enum ToolListChangedNotification: WireShape { public static let definition = FrozenWireDefinition.ToolListChangedNotification }
    public enum ToolResultContent: WireShape { public static let definition = FrozenWireDefinition.ToolResultContent }
    public enum ToolUseContent: WireShape { public static let definition = FrozenWireDefinition.ToolUseContent }
    public enum UnsupportedProtocolVersionError: WireShape { public static let definition = FrozenWireDefinition.UnsupportedProtocolVersionError }
    public enum UntitledMultiSelectEnumSchema: WireShape { public static let definition = FrozenWireDefinition.UntitledMultiSelectEnumSchema }
    public enum UntitledSingleSelectEnumSchema: WireShape { public static let definition = FrozenWireDefinition.UntitledSingleSelectEnumSchema }
}
/// Definition-specific checked aliases; see WireProjection for bounded construction.
public enum MCPWire {
    public typealias Annotations = WireProjection<WireShapes.Annotations>
    public typealias AudioContent = WireProjection<WireShapes.AudioContent>
    public typealias BaseMetadata = WireProjection<WireShapes.BaseMetadata>
    public typealias BlobResourceContents = WireProjection<WireShapes.BlobResourceContents>
    public typealias BooleanSchema = WireProjection<WireShapes.BooleanSchema>
    public typealias CacheableResult = WireProjection<WireShapes.CacheableResult>
    public typealias CallToolRequest = WireProjection<WireShapes.CallToolRequest>
    public typealias CallToolRequestParams = WireProjection<WireShapes.CallToolRequestParams>
    public typealias CallToolResult = WireProjection<WireShapes.CallToolResult>
    public typealias CallToolResultResponse = WireProjection<WireShapes.CallToolResultResponse>
    public typealias CancelledNotification = WireProjection<WireShapes.CancelledNotification>
    public typealias CancelledNotificationParams = WireProjection<WireShapes.CancelledNotificationParams>
    public typealias ClientCapabilities = WireProjection<WireShapes.ClientCapabilities>
    public typealias ClientNotification = WireProjection<WireShapes.ClientNotification>
    public typealias ClientRequest = WireProjection<WireShapes.ClientRequest>
    public typealias ClientResult = WireProjection<WireShapes.ClientResult>
    public typealias CompleteRequest = WireProjection<WireShapes.CompleteRequest>
    public typealias CompleteRequestParams = WireProjection<WireShapes.CompleteRequestParams>
    public typealias CompleteResult = WireProjection<WireShapes.CompleteResult>
    public typealias CompleteResultResponse = WireProjection<WireShapes.CompleteResultResponse>
    public typealias ContentBlock = WireProjection<WireShapes.ContentBlock>
    public typealias CreateMessageRequest = WireProjection<WireShapes.CreateMessageRequest>
    public typealias CreateMessageRequestParams = WireProjection<WireShapes.CreateMessageRequestParams>
    public typealias CreateMessageResult = WireProjection<WireShapes.CreateMessageResult>
    public typealias Cursor = WireProjection<WireShapes.Cursor>
    public typealias DiscoverRequest = WireProjection<WireShapes.DiscoverRequest>
    public typealias DiscoverResult = WireProjection<WireShapes.DiscoverResult>
    public typealias DiscoverResultResponse = WireProjection<WireShapes.DiscoverResultResponse>
    public typealias ElicitRequest = WireProjection<WireShapes.ElicitRequest>
    public typealias ElicitRequestFormParams = WireProjection<WireShapes.ElicitRequestFormParams>
    public typealias ElicitRequestParams = WireProjection<WireShapes.ElicitRequestParams>
    public typealias ElicitRequestURLParams = WireProjection<WireShapes.ElicitRequestURLParams>
    public typealias ElicitResult = WireProjection<WireShapes.ElicitResult>
    public typealias EmbeddedResource = WireProjection<WireShapes.EmbeddedResource>
    public typealias EmptyResult = WireProjection<WireShapes.EmptyResult>
    public typealias EnumSchema = WireProjection<WireShapes.EnumSchema>
    public typealias Error = WireProjection<WireShapes.Error>
    public typealias GetPromptRequest = WireProjection<WireShapes.GetPromptRequest>
    public typealias GetPromptRequestParams = WireProjection<WireShapes.GetPromptRequestParams>
    public typealias GetPromptResult = WireProjection<WireShapes.GetPromptResult>
    public typealias GetPromptResultResponse = WireProjection<WireShapes.GetPromptResultResponse>
    public typealias HeaderMismatchError = WireProjection<WireShapes.HeaderMismatchError>
    public typealias Icon = WireProjection<WireShapes.Icon>
    public typealias Icons = WireProjection<WireShapes.Icons>
    public typealias ImageContent = WireProjection<WireShapes.ImageContent>
    public typealias Implementation = WireProjection<WireShapes.Implementation>
    public typealias InputRequest = WireProjection<WireShapes.InputRequest>
    public typealias InputRequests = WireProjection<WireShapes.InputRequests>
    public typealias InputRequiredResult = WireProjection<WireShapes.InputRequiredResult>
    public typealias InputResponse = WireProjection<WireShapes.InputResponse>
    public typealias InputResponseRequestParams = WireProjection<WireShapes.InputResponseRequestParams>
    public typealias InputResponses = WireProjection<WireShapes.InputResponses>
    public typealias InternalError = WireProjection<WireShapes.InternalError>
    public typealias InvalidParamsError = WireProjection<WireShapes.InvalidParamsError>
    public typealias InvalidRequestError = WireProjection<WireShapes.InvalidRequestError>
    public typealias JSONArray = WireProjection<WireShapes.JSONArray>
    public typealias JSONObject = WireProjection<WireShapes.JSONObject>
    public typealias JSONRPCErrorResponse = WireProjection<WireShapes.JSONRPCErrorResponse>
    public typealias JSONRPCMessage = WireProjection<WireShapes.JSONRPCMessage>
    public typealias JSONRPCNotification = WireProjection<WireShapes.JSONRPCNotification>
    public typealias JSONRPCRequest = WireProjection<WireShapes.JSONRPCRequest>
    public typealias JSONRPCResponse = WireProjection<WireShapes.JSONRPCResponse>
    public typealias JSONRPCResultResponse = WireProjection<WireShapes.JSONRPCResultResponse>
    public typealias JSONValue = WireProjection<WireShapes.JSONValue>
    public typealias LegacyTitledEnumSchema = WireProjection<WireShapes.LegacyTitledEnumSchema>
    public typealias ListPromptsRequest = WireProjection<WireShapes.ListPromptsRequest>
    public typealias ListPromptsResult = WireProjection<WireShapes.ListPromptsResult>
    public typealias ListPromptsResultResponse = WireProjection<WireShapes.ListPromptsResultResponse>
    public typealias ListResourceTemplatesRequest = WireProjection<WireShapes.ListResourceTemplatesRequest>
    public typealias ListResourceTemplatesResult = WireProjection<WireShapes.ListResourceTemplatesResult>
    public typealias ListResourceTemplatesResultResponse = WireProjection<WireShapes.ListResourceTemplatesResultResponse>
    public typealias ListResourcesRequest = WireProjection<WireShapes.ListResourcesRequest>
    public typealias ListResourcesResult = WireProjection<WireShapes.ListResourcesResult>
    public typealias ListResourcesResultResponse = WireProjection<WireShapes.ListResourcesResultResponse>
    public typealias ListRootsRequest = WireProjection<WireShapes.ListRootsRequest>
    public typealias ListRootsResult = WireProjection<WireShapes.ListRootsResult>
    public typealias ListToolsRequest = WireProjection<WireShapes.ListToolsRequest>
    public typealias ListToolsResult = WireProjection<WireShapes.ListToolsResult>
    public typealias ListToolsResultResponse = WireProjection<WireShapes.ListToolsResultResponse>
    public typealias LoggingLevel = WireProjection<WireShapes.LoggingLevel>
    public typealias LoggingMessageNotification = WireProjection<WireShapes.LoggingMessageNotification>
    public typealias LoggingMessageNotificationParams = WireProjection<WireShapes.LoggingMessageNotificationParams>
    public typealias MetaObject = WireProjection<WireShapes.MetaObject>
    public typealias MethodNotFoundError = WireProjection<WireShapes.MethodNotFoundError>
    public typealias MissingRequiredClientCapabilityError = WireProjection<WireShapes.MissingRequiredClientCapabilityError>
    public typealias ModelHint = WireProjection<WireShapes.ModelHint>
    public typealias ModelPreferences = WireProjection<WireShapes.ModelPreferences>
    public typealias MultiSelectEnumSchema = WireProjection<WireShapes.MultiSelectEnumSchema>
    public typealias Notification = WireProjection<WireShapes.Notification>
    public typealias NotificationMetaObject = WireProjection<WireShapes.NotificationMetaObject>
    public typealias NotificationParams = WireProjection<WireShapes.NotificationParams>
    public typealias NumberSchema = WireProjection<WireShapes.NumberSchema>
    public typealias PaginatedRequest = WireProjection<WireShapes.PaginatedRequest>
    public typealias PaginatedRequestParams = WireProjection<WireShapes.PaginatedRequestParams>
    public typealias PaginatedResult = WireProjection<WireShapes.PaginatedResult>
    public typealias ParseError = WireProjection<WireShapes.ParseError>
    public typealias PrimitiveSchemaDefinition = WireProjection<WireShapes.PrimitiveSchemaDefinition>
    public typealias ProgressNotification = WireProjection<WireShapes.ProgressNotification>
    public typealias ProgressNotificationParams = WireProjection<WireShapes.ProgressNotificationParams>
    public typealias ProgressToken = WireProjection<WireShapes.ProgressToken>
    public typealias Prompt = WireProjection<WireShapes.Prompt>
    public typealias PromptArgument = WireProjection<WireShapes.PromptArgument>
    public typealias PromptListChangedNotification = WireProjection<WireShapes.PromptListChangedNotification>
    public typealias PromptMessage = WireProjection<WireShapes.PromptMessage>
    public typealias PromptReference = WireProjection<WireShapes.PromptReference>
    public typealias ReadResourceRequest = WireProjection<WireShapes.ReadResourceRequest>
    public typealias ReadResourceRequestParams = WireProjection<WireShapes.ReadResourceRequestParams>
    public typealias ReadResourceResult = WireProjection<WireShapes.ReadResourceResult>
    public typealias ReadResourceResultResponse = WireProjection<WireShapes.ReadResourceResultResponse>
    public typealias Request = WireProjection<WireShapes.Request>
    public typealias RequestId = WireProjection<WireShapes.RequestId>
    public typealias RequestMetaObject = WireProjection<WireShapes.RequestMetaObject>
    public typealias RequestParams = WireProjection<WireShapes.RequestParams>
    public typealias Resource = WireProjection<WireShapes.Resource>
    public typealias ResourceContents = WireProjection<WireShapes.ResourceContents>
    public typealias ResourceLink = WireProjection<WireShapes.ResourceLink>
    public typealias ResourceListChangedNotification = WireProjection<WireShapes.ResourceListChangedNotification>
    public typealias ResourceRequestParams = WireProjection<WireShapes.ResourceRequestParams>
    public typealias ResourceTemplate = WireProjection<WireShapes.ResourceTemplate>
    public typealias ResourceTemplateReference = WireProjection<WireShapes.ResourceTemplateReference>
    public typealias ResourceUpdatedNotification = WireProjection<WireShapes.ResourceUpdatedNotification>
    public typealias ResourceUpdatedNotificationParams = WireProjection<WireShapes.ResourceUpdatedNotificationParams>
    public typealias Result = WireProjection<WireShapes.Result>
    public typealias ResultMetaObject = WireProjection<WireShapes.ResultMetaObject>
    public typealias ResultType = WireProjection<WireShapes.ResultType>
    public typealias Role = WireProjection<WireShapes.Role>
    public typealias Root = WireProjection<WireShapes.Root>
    public typealias SamplingMessage = WireProjection<WireShapes.SamplingMessage>
    public typealias SamplingMessageContentBlock = WireProjection<WireShapes.SamplingMessageContentBlock>
    public typealias ServerCapabilities = WireProjection<WireShapes.ServerCapabilities>
    public typealias ServerNotification = WireProjection<WireShapes.ServerNotification>
    public typealias ServerResult = WireProjection<WireShapes.ServerResult>
    public typealias SingleSelectEnumSchema = WireProjection<WireShapes.SingleSelectEnumSchema>
    public typealias StringSchema = WireProjection<WireShapes.StringSchema>
    public typealias SubscriptionFilter = WireProjection<WireShapes.SubscriptionFilter>
    public typealias SubscriptionsAcknowledgedNotification = WireProjection<WireShapes.SubscriptionsAcknowledgedNotification>
    public typealias SubscriptionsAcknowledgedNotificationParams = WireProjection<WireShapes.SubscriptionsAcknowledgedNotificationParams>
    public typealias SubscriptionsListenRequest = WireProjection<WireShapes.SubscriptionsListenRequest>
    public typealias SubscriptionsListenRequestParams = WireProjection<WireShapes.SubscriptionsListenRequestParams>
    public typealias SubscriptionsListenResult = WireProjection<WireShapes.SubscriptionsListenResult>
    public typealias SubscriptionsListenResultMetaObject = WireProjection<WireShapes.SubscriptionsListenResultMetaObject>
    public typealias SubscriptionsListenResultResponse = WireProjection<WireShapes.SubscriptionsListenResultResponse>
    public typealias TextContent = WireProjection<WireShapes.TextContent>
    public typealias TextResourceContents = WireProjection<WireShapes.TextResourceContents>
    public typealias TitledMultiSelectEnumSchema = WireProjection<WireShapes.TitledMultiSelectEnumSchema>
    public typealias TitledSingleSelectEnumSchema = WireProjection<WireShapes.TitledSingleSelectEnumSchema>
    public typealias Tool = WireProjection<WireShapes.Tool>
    public typealias ToolAnnotations = WireProjection<WireShapes.ToolAnnotations>
    public typealias ToolChoice = WireProjection<WireShapes.ToolChoice>
    public typealias ToolListChangedNotification = WireProjection<WireShapes.ToolListChangedNotification>
    public typealias ToolResultContent = WireProjection<WireShapes.ToolResultContent>
    public typealias ToolUseContent = WireProjection<WireShapes.ToolUseContent>
    public typealias UnsupportedProtocolVersionError = WireProjection<WireShapes.UnsupportedProtocolVersionError>
    public typealias UntitledMultiSelectEnumSchema = WireProjection<WireShapes.UntitledMultiSelectEnumSchema>
    public typealias UntitledSingleSelectEnumSchema = WireProjection<WireShapes.UntitledSingleSelectEnumSchema>
}
