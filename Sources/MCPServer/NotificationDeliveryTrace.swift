// SPDX-License-Identifier: Apache-2.0
// DIAGNOSTIC ONLY. Do not merge into main or PR #61.
import Foundation
import Synchronization
import MCPProtocol

/// Fixed classifications and process-local random channel IDs only. No raw
/// requests, user identities, wire IDs, URIs, payloads or credentials.
enum NotificationDeliveryTrace {
    static let enabled = ProcessInfo.processInfo.environment["MCP_A16N_TRACE"] == "1"
    private static let sequence = Mutex<Int>(0)
    static func mark(_ event: String, channel: UUID? = nil, kind: String = "-", detail: String = "") {
        guard enabled else { return }
        sequence.withLock { count in
            guard count < 4096 else { return }
            count += 1
            let label = count == 4096 ? "trace.limit" : event
            let line = "N2_TRACE ns=\(DispatchTime.now().uptimeNanoseconds) seq=\(count) event=\(label) channel=\(channel?.uuidString ?? "-") kind=\(kind) \(detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
    static func kind(_ definition: FrozenWireDefinition?) -> String? {
        guard let definition else { return nil }
        switch definition {
        case .SubscriptionsAcknowledgedNotification: return "ack"
        case .ToolListChangedNotification: return "tools"
        case .PromptListChangedNotification: return "prompts"
        case .CancelledNotification: return "cancel"
        default: return nil
        }
    }
    static func failure(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        switch error as? CoreFailure {
        case .some(.deadline): return "deadline"
        case .some(.eventsUnavailable): return "eventsUnavailable"
        case .some(.disconnected): return "disconnected"
        case .some(.eventOverflow): return "overflow"
        default: return "other"
        }
    }
}
