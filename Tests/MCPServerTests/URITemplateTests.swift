// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer
import Testing

private func uriValue(_ value: JSON, budget: RequestBudget) async throws -> String? {
    switch value {
    case .string(let text): return text
    case .number(let number):
        var limits = JSONLimits.balanced
        for metric in [JSONResourceMetric.compileWorkUnits, .evaluationWorkUnits, .regexCompileWorkUnits, .aggregateRegexWorkUnits] { limits[metric] = 0 }
        return try await budget.performUnreported(workUnits: 4096, limits: limits) { try number.numericText(style: .preserved, limits: $0) }
    case .boolean(let value): return value ? "true" : "false"
    case .null: return nil
    default: throw CoreFailure.invalidInput
    }
}

@Test func publicRFC6570CorpusIsUnchangedAndEveryCaseExecutes() async throws {
    var executed = 0
    var authorityDisagreements = 0
    for name in ["spec-examples", "spec-examples-by-section", "extended-tests", "negative-tests"] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources/URITemplates"))
        let groups = try JSONParser().parse(Data(contentsOf: url)).objectValue!
        for group in groups {
            let object = group.value.objectValue!, budget = try RequestBudget(workUnits: 8_000_000)
            var values: [ScalarText: URIValue] = [:]
            for member in object["variables"]!.objectValue! {
                let value: URIValue?
                switch member.value {
                case .array(let array):
                    var list: [String?] = []; for element in array { list.append(try await uriValue(element, budget: budget)) }; value = .list(list)
                case .object(let map):
                    var pairs: [URIValue.Pair] = []; for item in map { pairs.append(.init(item.key.string, try await uriValue(item.value, budget: budget))) }; value = .map(pairs)
                default: value = try await uriValue(member.value, budget: budget).map(URIValue.string)
                }
                if let value { values[ScalarText(member.key.string)] = value }
            }
            for example in object["testcases"]!.arrayValue! {
                executed += 1
                let pair = example.arrayValue!, template = pair[0].stringValue!, expected = pair[1]
                let account = try RequestBudget(workUnits: 8_000_000)
                // Two public corpus rows use apostrophe literals forbidden by
                // RFC6570 §2.1. Retain and execute them under the dated standard,
                // recording the disagreement instead of weakening the grammar.
                if (name == "spec-examples" && template == "'{var}'") ||
                   (name == "spec-examples-by-section" && template == "'{count}'") {
                    authorityDisagreements += 1
                    await #expect(throws: CoreFailure.invalidInput) { try await URITemplate.prepare(template, budget: account) }
                } else if expected == .boolean(false) {
                    await #expect(throws: (any Error).self) {
                        let plan = try await URITemplate.prepare(template, budget: account)
                        _ = try await plan.expand(values, budget: account)
                    }
                } else {
                    do {
                        let plan = try await URITemplate.prepare(template, budget: account)
                        let actual = try await plan.expand(values, budget: account)
                        let accepted = expected.arrayValue?.compactMap { $0.stringValue } ?? [expected.stringValue!]
                        #expect(accepted.contains(actual), "\(name): \(template) -> \(actual)")
                    } catch { Issue.record("\(name) / \(group.key.string) / \(template): \(error)") }
                }
            }
        }
    }
    #expect(executed > 200)
    #expect(authorityDisagreements == 2)
    print("RFC6570 corpus: \(executed) rows executed; 2 retained literal-apostrophe authority disagreements; no skipped rows")
}

@Test func templateUnicodePrefixesPercentNamesAndFiniteExpansion() async throws {
    let account = try RequestBudget(workUnits: 8_000_000)
    let unicode = try await URITemplate.prepare("{text:1}/{+encoded:1}{?%C3%A9}", budget: account)
    let result = try await unicode.expand([ScalarText("text"): .string("e\u{301}"), ScalarText("encoded"): .string("%C3%A9x"),
        ScalarText("%C3%A9"): .string("first"), ScalarText("é"): .string("second")], budget: account)
    #expect(result == "e/%C3%A9?%C3%A9=first")
    let bounded = try RequestBudget(workUnits: 100_000)
    let plan = try await URITemplate.prepare("{text}", budget: bounded)
    await #expect(throws: CoreFailure.limit) { try await plan.expand([ScalarText("text"): .string("long")], maximumBytes: 2, budget: bounded) }
    #expect(await bounded.snapshot.isTerminal)
    let duplicates = try RequestBudget(workUnits: 100_000)
    await #expect(throws: CoreFailure.duplicate) { try await plan.expand([ScalarText("text"): .map([.init("x", "1"), .init("x", "2")])], budget: duplicates) }
}
