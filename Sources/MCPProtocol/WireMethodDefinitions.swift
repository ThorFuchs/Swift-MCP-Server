// SPDX-License-Identifier: Apache-2.0
extension WireMethod {
    public var definition: FrozenWireDefinition {
        switch self {
        case .callTool: .CallToolRequest
        case .cancelled: .CancelledNotification
        case .complete: .CompleteRequest
        case .createMessage: .CreateMessageRequest
        case .discover: .DiscoverRequest
        case .elicit: .ElicitRequest
        case .getPrompt: .GetPromptRequest
        case .listPrompts: .ListPromptsRequest
        case .listResourceTemplates: .ListResourceTemplatesRequest
        case .listResources: .ListResourcesRequest
        case .listRoots: .ListRootsRequest
        case .listTools: .ListToolsRequest
        case .logMessage: .LoggingMessageNotification
        case .progress: .ProgressNotification
        case .promptsChanged: .PromptListChangedNotification
        case .readResource: .ReadResourceRequest
        case .resourcesChanged: .ResourceListChangedNotification
        case .resourceUpdated: .ResourceUpdatedNotification
        case .acknowledged: .SubscriptionsAcknowledgedNotification
        case .listen: .SubscriptionsListenRequest
        case .toolsChanged: .ToolListChangedNotification
        }
    }
    public var resultDefinition: FrozenWireDefinition? {
        switch self {
        case .callTool: .CallToolResult
        case .complete: .CompleteResult
        case .createMessage: .CreateMessageResult
        case .discover: .DiscoverResult
        case .elicit: .ElicitResult
        case .getPrompt: .GetPromptResult
        case .listPrompts: .ListPromptsResult
        case .listResourceTemplates: .ListResourceTemplatesResult
        case .listResources: .ListResourcesResult
        case .listRoots: .ListRootsResult
        case .listTools: .ListToolsResult
        case .readResource: .ReadResourceResult
        case .listen: .SubscriptionsListenResult
        default: nil
        }
    }
}
