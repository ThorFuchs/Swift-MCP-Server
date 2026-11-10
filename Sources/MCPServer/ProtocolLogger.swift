// SPDX-License-Identifier: Apache-2.0
public enum ProtocolLogLevel: String, Sendable, CaseIterable {
    case debug, info, notice, warning, error, critical, alert, emergency
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}
