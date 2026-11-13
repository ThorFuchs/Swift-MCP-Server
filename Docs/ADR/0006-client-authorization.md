# ADR-0006: Client authorization (`MCPClientAuthorization`) and DPoP

- Status: **Proposed** (2026-11-12)
- Builds on ADR-0005 (client); covers roadmap C3 (slices A1–A6) and S5 (resource-server DPoP)

## Context

MCP 2026-07-28 protects HTTP servers with OAuth 2.1. A client that meets a `401` must
find the protected resource metadata (RFC 9728, from `WWW-Authenticate` or the
well-known paths), the authorization server metadata (RFC 8414 or OpenID Connect
discovery, including path-inserted variants), identify itself (a client ID metadata
document, a pre-registered client, or dynamic client registration, RFC 7591), run the
authorization code flow with PKCE `S256` and the `resource` indicator (RFC 8707), check
`iss` (RFC 9207), choose scopes (from the challenge, else `scopes_supported`, else none),
step up on `403 insufficient_scope` with a retry limit, refresh tokens (`offline_access`)
and follow an authorization server migration. Extensions add client credentials (JWT and
basic), enterprise-managed authorization, workload identity federation (JWT bearer) and
DPoP (RFC 9449) with server nonces.

The official referee covers this with 25 `auth/*` client scenarios for 2026-07-28 and 6
extension scenarios (conformance 0.2.0-alpha.12). The server side already has protected
resource metadata, bounded Bearer challenges and a host `TokenVerifier`
(`MCPHTTPAuthorization`); it has no DPoP.

Options reviewed: AppAuth (Apple platforms only, Objective-C), community OAuth packages
(unmaintained or heavy), and a JOSE stack such as jwt-kit (large dependency for the two
signatures we need).

## Decision

1. **Product and place.** `MCPClientAuthorization` in Swift-MCP-Server-HTTP, next to
   `MCPHTTPClient`, because authorization exists only over HTTP. Dependencies:
   `MCPHTTPClient`, AsyncHTTPClient (already used), CryptoKit / swift-crypto, and
   Swift-JSON for **every** JSON document (metadata, registration, token responses, JWT
   claims) with explicit `JSONLimits`, and Swift-JSON's `JSONSchema` where a document has a
   schema. No `JSONSerialization`, no `Codable` decoding of untrusted documents, no other
   OAuth or JOSE package.
2. **Transport hook.** `HTTPClientTransport(endpoint:authorization:)` takes an
   `HTTPClientAuthorizing` value. Before each request it supplies headers (`Authorization`
   and, with DPoP, `DPoP`); on `401`, `403 insufficient_scope` or `use_dpop_nonce` it
   decides whether to retry. The transport retries a request at most once per
   authorization step and never retries a request whose body it already streamed.
3. **`OAuthClient` actor** owns the flow: discovery (A1), client identity (A2), code flow
   (A3), scopes and refresh (A4), migration (A5). Metadata is cached per resource with the
   server's cache directives and bounded size; refresh is single-flight per token.
4. **The host owns credentials and user interaction** (no library-owned secrets):
   - `AuthorizationUserAgent`: opens the authorization URL and returns the redirect
     (`code`, `state`, `iss`). Hosts use `ASWebAuthenticationSession`, a loopback listener
     or a device-specific flow; the library supplies none.
   - `TokenStore`: load, save and delete tokens keyed by resource, issuer and client ID. An
     in-memory store ships for tests; a Keychain store may follow as a separate product.
   - `ClientIdentity`: a client ID metadata document URL, a pre-registered client
     (secret or `private_key_jwt`), or permission to register dynamically.
   - `SigningKey`: ES256 (P-256) signing for `private_key_jwt` and DPoP proofs; hosts may
     back it with the Secure Enclave.
5. **Security rules, enforced, not configurable:** HTTPS for every authorization endpoint
   except loopback in explicit development mode; exact issuer match between metadata,
   `iss` and the token response context; resource and audience match; PKCE `S256` only;
   `state` checked; redirect URIs compared exactly; tokens sent only to the resource and
   the issuing server; tokens and codes never logged; every response body bounded.
6. **JOSE scope:** compact JWS with ES256 only (sign on the client; verify on the server
   for DPoP), built on CryptoKit / swift-crypto. Other algorithms are rejected.
7. **DPoP on both sides (A6 with S5).** The client creates proofs (`htm`, `htu`, `iat`,
   `jti`, `ath`, `nonce`) and handles `DPoP-Nonce`. `MCPHTTPAuthorization` gains optional
   proof verification: signature, method and URL, `iat` window, `ath`, the token's
   `cnf.jkt` binding (from the host `TokenVerifier`), nonces, and replay detection through a
   bounded host-supplied `jti` store.
8. **Conformance gate.** `Scripts/client-conformance.sh` adds each `auth/*` scenario as its
   slice lands; the gate never lists a scenario that is not expected to pass.

Order: A1–A3 first (the interactive authorization code case), then A4–A6.

## Consequences

- One small, auditable implementation with the dependencies the SDK already has; Apple
  platforms and Linux behave the same.
- Hosts keep full control over browsers, storage and keys, which a reusable library must
  not own.
- ES256-only JWS keeps the cryptography surface small. Servers that require RS256 client
  assertions are not supported until a host asks for it.
- The resource server can require DPoP-bound tokens with the same JWS code the client uses.
