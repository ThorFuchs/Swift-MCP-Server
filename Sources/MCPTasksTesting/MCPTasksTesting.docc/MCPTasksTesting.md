# ``MCPTasksTesting``

Exercise the common behavioral contract of a task-store backend.

## Overview

The ``TaskStoreConformanceKit`` runs checks with fresh store instances. Supply a reopen operation when persistence across instances is supported. Checks use millisecond timestamp precision and require payload round trips. A backend that omits reopen support does not thereby establish durability.

Inspect every check result in the application's own test suite. This kit verifies store behavior, not the complete runtime or external-effect semantics.

## Topics

- ``TaskStoreConformanceKit``
