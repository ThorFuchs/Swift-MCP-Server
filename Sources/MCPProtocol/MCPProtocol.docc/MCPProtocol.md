# ``MCPProtocol``

Represent the frozen MCP 2026-07-28 wire format with exact JSON values.

``WireCodec`` parses and writes with public Swift-JSON reports and finite limits.
``RequestID`` retains mathematical integers beyond Double precision and scalar-exact
strings. ``ScalarText`` keeps canonically equivalent Unicode spellings distinct where
protocol identity requires it. Values never pass through Foundation JSONSerialization.

``FrozenWireSchema`` reads and verifies the dated bundled schema. Its 155 definitions,
``WireDefinitionPlan`` and ``WireProjection`` preserve allowed unknown fields and
schema-defined presence. Ordinary invalidity returns reported false/nil; operational
limits, unsupported assertions and cancellation throw. ``WireMethod`` contains the
21 dated selectors. Roots, sampling and elicitation are multi-round inputs.

The server settles reports through its private adapter and cumulative request account.
A host using these low-level APIs owns its own finite account. This product does not
provide a client or protocol negotiation. The independent full consumer calls WireCodec
and RequestID while checking exact IDs through real transports.

## Topics

### Exact wire values
- ``WireCodec``
- ``RequestID``
- ``ScalarText``
- ``WireMethod``

### Frozen validation
- ``FrozenWireSchema``
- ``WireDefinitionPlan``
- ``WireProjection``

## Bundled schema ownership

`FrozenWireSchema.read(maximumBytes:)` selects the package's generated `Bundle.module`.
The `.copy("Resources")` directory is preserved intact. Raw SwiftPM bundles store
`Resources/schema.json` directly under the bundle root; canonical packaged macOS
bundles store it at `Contents/Resources/Resources/schema.json`. Foundation may return
the copied directory as the flat bundle's `resourceURL`; the SDK does not append a
second directory to that URL. Packaging must preserve the module bundle identity
and logical resource paths, and make that bundle discoverable by the generated
accessor. This API does not select a different main bundle or search alternate
schema copies when the selected resource fails.

The byte admission, at-most-181475-byte read and exact 181474-byte SHA-256 check
are unchanged. Missing/unreadable files propagate the I/O error; invalid size/hash
or unrecognized layout throws `WireFailure.invalidRequest`; insufficient byte
admission throws `WireFailure.limit`. Parsing and schema work retain their separate
finite accounts. SDK-S01 changes and layout acceptance tests are source only until
separately admitted compilation, raw SwiftPM and packaged-consumer qualification.
