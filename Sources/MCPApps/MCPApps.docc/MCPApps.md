# ``MCPApps``

Publish server-side MCP Apps views and tool annotations.

## Overview

An ``AppView`` describes a UI resource with HTML content and metadata. Annotate tool definitions with the view resource URI and validate the combined definitions before registration. A host without Apps support should still receive meaningful ordinary tool content.

The server publishes metadata such as CSP and requested permissions. Rendering, sandboxing, permission enforcement and user interaction remain responsibilities of the host. This package does not provide a browser or UI runtime.

## Topics

- ``AppView``
- ``AppViewMetadata``
- ``AppContentSecurityPolicy``
- ``AppPermission``
- ``AppToolVisibility``
- ``AppDefinitionError``
