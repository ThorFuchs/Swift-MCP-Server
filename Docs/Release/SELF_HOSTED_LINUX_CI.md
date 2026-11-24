# Core CI — opt-in self-hosted Linux

## Scope
Routing only. The `linux` job, existing Swift 6.4.2 Ubuntu 24.04 multi-architecture container digest, checkout pin, job timeout and `Scripts/test.sh` remain unchanged. Architecture and toolchain are logged. No platform support or release gate is removed.

## Runner requirements
- Repository-scoped Linux ARM64 runner in an Ubuntu VM; Docker daemon accessible by the actual runner service account.
- Labels `self-hosted`, `Linux`, `ARM64`, `swift-ci-linux`.
- The pinned Swift image must resolve natively for linux/arm64. An AMD64-only image or emulation is not an ARM64 qualification.

## Enable / disable
Set the repository Actions variable (requires appropriate maintainer access):

    gh variable set USE_SELF_HOSTED_LINUX --repo ThorFuchs/Swift-MCP-Server --body true

To restore hosted Ubuntu, set the variable to false (or remove it):

    gh variable set USE_SELF_HOSTED_LINUX --repo ThorFuchs/Swift-MCP-Server --body false

Existing queued/finished runs retain their workflow revision. Start a fresh workflow run on a ref containing this change; update other PR branches to include the routing change before using the new Linux runner.

## Trust boundary
The checked-in workflow routes fork pull requests to hosted Ubuntu regardless of the variable. This is not a security boundary against a malicious workflow change: persistent self-hosted runners must only be available to trusted contributors and trusted workflow definitions. Before opening the repository publicly, review runner access and isolation or disable persistent self-hosted runners. Keep `pull_request_target` out of this execution path. Docker group membership confers host-equivalent privileges inside the VM; do not expose host secrets or mount the macOS home directory.

## Qualification
Verify the actual runner assignment, `uname -sm` (`aarch64` in the container), Swift 6.4.2, and the full `Scripts/test.sh` result on the exact SHA. A green hosted AMD64 run is not an ARM64 receipt, and an ARM64 pass does not replace AMD64 compatibility validation. Keep both as distinct release evidence. No artifact-storage quota is waived or hidden by this change.

Initial infrastructure status: user reports VM and runner registration; remote runner list access is unavailable to the implementation session. No native ARM64 container job pass claimed before a real receipt.
