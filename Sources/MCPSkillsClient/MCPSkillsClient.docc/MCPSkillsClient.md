# ``MCPSkillsClient``

Fetch advertised skill metadata and verify on-demand file contents.

## Overview

Use ``SkillsClient`` with the existing MCP client. Listing and lookup return entries without fetching every file. Loading a skill verifies the SKILL.md bytes against the advertised size and digest and checks its parsed frontmatter. Other files must belong to the manifest and pass their own digest and size checks.

A mismatch throws rather than returning unverified content. Integrity verification does not imply that a skill is trusted or authorized to execute.

## Topics

- ``SkillsClient``
- ``SkillEntry``
- ``SkillFileEntry``
- ``LoadedSkill``
- ``SkillVerificationError``
