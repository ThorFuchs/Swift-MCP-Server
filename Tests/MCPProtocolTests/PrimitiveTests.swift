// SPDX-License-Identifier: Apache-2.0
import Testing
import MCPProtocol

@Test func scalarNamesRemainDistinct() {
    let composed = ScalarText("\u{e9}")
    let decomposed = ScalarText("e\u{301}")
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
    #expect(ScalarText("a") == ScalarText("a"))
}

@Test func methodInventoryAndPolicies() {
    #expect(WireMethod.allCases.count == 21)
    #expect(WireMethod.allCases.filter { $0.leg == .clientRequest }.count == 10)
    #expect(WireMethod.allCases.filter { $0.leg == .inputRequest }.count == 3)
    #expect(WireMethod.allCases.filter { $0.leg == .serverNotification }.count == 8)
    #expect(Set(WireMethod.allCases.filter(\.permitsInputRequired)) == [.callTool, .getPrompt, .readResource])
    #expect(WireMethod.allCases.filter(\.requiresCacheHints).count == 6)
    #expect(WireMethod.readResource.mirroredNameField == "uri")
    #expect(WireMethod.callTool.mirroredNameField == "name")
}

@Test(arguments: ["initialize", "ping", "logging/setLevel", "resources/subscribe",
                  "resources/unsubscribe", "tools/CALL", "tasks/get", "notifications/initialized"])
func excludedMethods(_ text: String) { #expect(WireMethod(rawValue: text) == nil) }
