// SPDX-License-Identifier: Apache-2.0
/// Value constraints incorporated by the frozen Basic metadata rule. These are
/// registration-time JSON Schema overlays, evaluated by public Swift-JSON with
/// the caller's existing work/regex limits and reports. No second regex engine,
/// trace adoption, decoding, normalization or input-dependent schema is added.
/// Authority: W3C Trace Context REC 2021-11-23, sections 3.2/3.3;
/// W3C Baggage CR 2024-05-30, section 3.3. See Docs/RC1/S01.md.
struct TraceMetadataRules: Encodable, Sendable {
    private struct Pattern: Encodable, Sendable { let pattern: String }
    private struct Exclusion: Encodable, Sendable { let not: Pattern }
    private struct Rule: Encodable, Sendable {
        let type = "string"
        let pattern: String
        let allOf: [Exclusion]
        init(_ pattern: String, excluding: [String]) {
            self.pattern = pattern
            allOf = excluding.map { Exclusion(not: Pattern(pattern: $0)) }
        }
    }
    private enum Key: String, CodingKey { case traceparent, tracestate, baggage }

    // Version00 is exactly55 ASCII bytes. Future versions retain the known
    // prefix and may append opaque fields after a dash; ff is always forbidden.
    // Unknown flag bits and future fields are neither interpreted nor rewritten.
    private static let parent = Rule(
        #"^(?:00|0[1-9a-f]|[1-9a-e][0-9a-f]|f[0-e])-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}(?:-[\x21-\x7e]*)?$"#,
        excluding: [
            #"[^\x21-\x7e]"#,
            #"^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}-"#,
            #"^[0-9a-f]{2}-0{32}-"#,
            #"^[0-9a-f]{2}-[0-9a-f]{32}-0{16}-"#
        ])
    private static let ows = #"[\x20\x09]*"#
    private static let stateKey = #"(?:[a-z][a-z0-9_*/-]{0,255}|[a-z0-9][a-z0-9_*/-]{0,240}@[a-z][a-z0-9_*/-]{0,13})"#
    private static let stateValue = #"[\x20-\x2b\x2d-\x3c\x3e-\x7e]{0,255}[\x21-\x2b\x2d-\x3c\x3e-\x7e]"#
    private static let stateMember = "(?:" + stateKey + "=" + stateValue + "|" + ows + ")"
    // Empty/OWS members are valid. Duplicate nonempty keys are not. The bounded
    // backreference runs in Swift-JSON's metered regex VM, not Foundation regex.
    private static let state = Rule(
        "^" + ows + stateMember + "(?:" + ows + "," + ows + stateMember + "){0,31}" + ows + "$",
        excluding: [
            #"[^\x20-\x7e\x09]"#,
            #"(?:^|,)[\x20\x09]*([a-z0-9_*/@-]+)=[^,]*(?:,[^,]*)*,[\x20\x09]*\1="#
        ])
    private static let baggageKey = #"[!#$%&'*+.^_`|~0-9A-Za-z-]+"#
    // Percent escapes are validated but retained, including encoded octets that
    // would require replacement on decoding. Duplicate baggage keys are allowed.
    private static let baggageValue = #"(?:[\x21\x23-\x24\x26-\x2b\x2d-\x3a\x3c-\x5b\x5d-\x7e]|%[0-9A-Fa-f]{2})*"#
    private static let baggageProperty = baggageKey + ows + "(?:=" + ows + baggageValue + ")?"
    private static let baggageMember = baggageKey + ows + "=" + ows + baggageValue + ows + "(?:;" + ows + baggageProperty + ows + ")*"
    private static let baggage = Rule(
        "^" + ows + baggageMember + "(?:," + ows + baggageMember + "){0,179}$",
        excluding: [#"[^\x20-\x7e\x09]"#])

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(Self.parent, forKey: .traceparent)
        try fields.encode(Self.state, forKey: .tracestate)
        try fields.encode(Self.baggage, forKey: .baggage)
    }
}
