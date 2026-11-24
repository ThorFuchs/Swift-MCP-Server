# ``MCPTasksSQLite``

Persist task records using Swift-SQLite.

## Overview

``SQLiteTaskStore`` implements the task-store contract with a SQLite database. Open one store per file and process, and close it when the host is finished. Migrations, finite payload limits and version-checked state transitions preserve the store contract. The owner is part of task access, not merely a display attribute.

Core's release qualification selects Swift-SQLite 1.2.0 in its three local workspaces. This does not enable optional model-layer or change-log features. Use the store conformance kit and native reopen tests when qualifying a new dependency version.

## Topics

- ``SQLiteTaskStore``
