# Skills (`MCPSkills`)

`MCPSkills` serves [Agent Skills](https://agentskills.io/) through the official Skills
extension (`io.modelcontextprotocol/skills`, SEP-2640, beta, against protocol 2026-07-28).
Every skill file is a `skill://` resource read with `resources/read`. `skills/list` and
`skills/get` return complete manifests with SHA-256 digests and sizes, and
`resources/directory/read` lists every directory level (`directoryRead: true`).

## Setup

```swift
let skills = try SkillCatalog.load(directory: skillsDirectory, prefix: "acme")  // or SkillCatalog([SkillSource(...)])
let server = try await Server.make(info: info,
    catalog: ServerCatalog(resources: skills.resources(), extensions: [skills.registration()]), cursors: cursors)
```

`load(directory:)` serves every directory that contains a `SKILL.md`, nested skills
included. A skill's manifest lists all regular files below its directory. Hidden files are
skipped and symbolic links are rejected.

## Behavior

- **Server-declared.** The server declares the extension in `server/discover`; clients call
  `skills/list`, `skills/get` and `resources/directory/read` without declaring it.
- **Validated when built.** A catalog is rejected, never partly served, when a skill lacks
  `SKILL.md`, its frontmatter does not parse, `name` breaks the Agent Skills naming rules or
  differs from the final path segment, `description` is empty, `metadata` uses the reserved
  `io.modelcontextprotocol/` prefix, a path segment is not an unreserved URI segment, the
  skill exceeds 512 files or 16 MiB, or an enclosing skill omits a nested skill's files.
- **Frontmatter.** Served verbatim as JSON. The parser accepts the YAML subset Agent Skills
  use (block mappings and sequences, plain and quoted scalars, `|`/`>` block scalars, flow
  sequences of scalars, comments) and rejects anchors, aliases, tags, flow mappings, tabs,
  duplicate keys and non-decimal numbers rather than guessing.
- **Resources.** `SKILL.md` is `text/markdown` with the frontmatter `name` and `description`;
  other files get a MIME type from their extension. Text is served as `text`, everything
  else as base64 `blob`; digests and sizes cover the raw bytes.
- **Errors.** Unknown skill URIs, non-directories and malformed or out-of-range cursors are
  `-32602`. `SkillCatalogConfiguration.requiredScopes` protects every method and file.
- **Caching.** Results carry `ttlMs` (default 5 minutes) and `cacheScope` (`public`, or
  `private` when scopes are required).

## Not yet implemented

- Dynamic skills (`"resources": "dynamic"`) and catalogs that change at runtime.
