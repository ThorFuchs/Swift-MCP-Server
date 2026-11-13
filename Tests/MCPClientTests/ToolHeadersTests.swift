// SPDX-License-Identifier: Apache-2.0
import Testing
import JSON
import MCPClient
import MCPProtocol

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }

@Suite struct ToolHeaderCases {
    @Test func valuesAreEncodedLikeTheSpecificationExamples() {
        #expect(HeaderValue.encode("us-west1") == "us-west1")
        #expect(HeaderValue.encode("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?=")
        #expect(HeaderValue.encode(" padded ") == "=?base64?IHBhZGRlZCA=?=")
        #expect(HeaderValue.encode("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?=")
        #expect(HeaderValue.encode("=?base64?literal?=") == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
        #expect(HeaderValue.encode("") == "")
    }

    @Test func annotatedPrimitivesAreMirroredByExactPath() throws {
        let headers = try ToolHeaders(inputSchema: json(#"""
            {"type":"object","properties":{
              "region":{"type":"string","x-mcp-header":"Region"},
              "priority":{"type":"integer","x-mcp-header":"Priority"},
              "debug":{"type":"boolean","x-mcp-header":"Debug"},
              "options":{"type":"object","properties":{"zone":{"type":"string","x-mcp-header":"Zone"}}},
              "query":{"type":"string"}}}
            """#))
        let mirrored = headers.headers(for: try json(#"{"region":"us-west1","priority":42,"debug":false,"options":{"zone":"Hello, 世界"},"query":"x"}"#))
        #expect(mirrored.map { "\($0.name): \($0.value)" }.sorted() == [
            "Mcp-Param-Debug: false", "Mcp-Param-Priority: 42", "Mcp-Param-Region: us-west1", "Mcp-Param-Zone: =?base64?SGVsbG8sIOS4lueVjA==?="])
        // Absent and null values have no header.
        #expect(headers.headers(for: try json(#"{"region":null}"#)).isEmpty)
    }

    @Test(arguments: [
        #"{"type":"object","properties":{"a":{"type":"number","x-mcp-header":"A"}}}"#,                         // number
        #"{"type":"object","properties":{"a":{"type":"object","x-mcp-header":"A"}}}"#,                         // object
        #"{"type":"object","properties":{"a":{"type":"string","x-mcp-header":""}}}"#,                          // empty
        #"{"type":"object","properties":{"a":{"type":"string","x-mcp-header":"Bad Name"}}}"#,                  // not a token
        #"{"type":"object","properties":{"a":{"type":"string","x-mcp-header":"X"},"b":{"type":"string","x-mcp-header":"x"}}}"#, // duplicate
        #"{"type":"object","properties":{"a":{"type":"array","items":{"type":"string","x-mcp-header":"A"}}}}"#, // through items
        #"{"type":"object","anyOf":[{"properties":{"a":{"type":"string","x-mcp-header":"A"}}}]}"#,           // through anyOf
        #"{"type":"object","$defs":{"d":{"type":"string","x-mcp-header":"A"}}}"#,                             // in $defs
        #"{"type":"string","x-mcp-header":"Root"}"#,                                                          // on the root
    ])
    func invalidAnnotationsInvalidateTheTool(_ schema: String) throws {
        #expect(throws: ToolHeaders.Invalid.self) { try ToolHeaders(inputSchema: json(schema)) }
    }
}
