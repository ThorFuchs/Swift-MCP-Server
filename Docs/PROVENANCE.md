# Provenance and licensing

Original scaffold and original implementation use Apache-2.0. Reference material retains its full
upstream LICENSE and source attribution. MCP/conformance repositories contain a licensing transition:
new code/spec under Apache-2.0, other documentation under CC-BY-4.0 and some historical contributions
remaining MIT. Treat each adapted file according to its actual upstream notice; package metadata alone
does not settle it. Retain this complete transition notice in redistributed snapshots.

Contracts/reference-manifest.json records every reference file's byte length, SHA-256, Git blob, upstream
path/repository and frozen commit. Source bytes were revalidated before packaging. The 176 protocol files
and selected referee sources are public; no prior private planning reports or application source is bundled.
Planning authority records hashes only, and the public contracts restate the neutral package decisions.

MCP snapshot: https://github.com/modelcontextprotocol/modelcontextprotocol/tree/c518f7a927cff918bce35d3522fcdb046d264d7c
Referee: https://github.com/modelcontextprotocol/conformance/tree/f44482ba17df816d3176962a11cdf36aec9bda00
Candidate SDK/platform source commits are recorded in Contracts/dependencies.json. If code is adapted
from any SDK, preserve its file notice, record original path/commit and describe the adaptation in NOTICE.
Do not copy legacy/client runtime machinery simply to simplify a port.

P12 audits the complete actual dependency graph and generated release notices after native resolution.
Root LICENSE does not override Reference licensing. Do not distribute keys/tokens, .build raw logs,
helper scripts containing environment credentials, app data, private reports or unreviewed fixture traces.

`Contracts/reference-verification.json` records the match of all 194 redistributed public files to expected
upstream Git blobs, independently of the computed ZIP inventory. This is byte provenance, not native
qualification or a promise of compatibility between source snapshots.

M01 intake retains the verified JSON candidate/envelope privately under .build and
consumes it as a dependency. No JSON engine was copied or modified. The integration
fixture copies the exact 20 vectors from the candidate's Tools/MCPReadiness resource
directory and the schema from the frozen MCP Reference, retaining their complete
LICENSE/NOTICE in Tools/JSONIntegration/Tests/IntegrationTests/Resources. Original
server adapters, tests and archive-intake tooling remain Apache-2.0. Upstream
verification scripts execute only in the fresh materialized copy and are not
relicensed as server code; their original source hashes remain in the receipt.

The production-backed referee fixture adapts synthetic behavior from the exact
pinned everything-server and scenario sources, with its full upstream notice at
Tools/Conformance/SwiftFixture/UPSTREAM_LICENSE. The omitted MRTR helper was fetched
read-only at that same commit and is retained in the private review evidence. All
194immutable Reference bytes remain unchanged. Actual installed referee code, both
schemas, dated requirements, npm locks, input blobs and failure history are retained;
the referee and frozen schema are never edited to satisfy conformance.

Acceptance v0.6 adds original Apache-2.0 middleware, generic supplemental plumbing,
profile factories, executable examples and benchmark/evidence tools. It retains every
Reference byte and the approved766-file NIO candidate. Synthetic example certificates
come from existing public test fixtures. Local SCM preserves the real upstream parent
and one-file patch; it has not been published or substituted for a public dependency.
No Swift-JSON implementation or upstream source is copied/changed by this sprint.
