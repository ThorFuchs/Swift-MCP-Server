# Releasing

1. `main` is green in CI (`Scripts/test.sh` on macOS 27).
2. Audit dependency licenses: for every package in `Package.resolved`, confirm the license and
   add any required attribution to `NOTICE`.
3. Generate the documentation (`swift package generate-documentation`) and check that it builds
   without warnings for the public products.
4. Update `CHANGELOG.md` and open a release PR.
5. After merge, tag `X.Y.Z` (or `X.Y.Z-rc.N`) on `main` and publish GitHub release notes.
6. Smoke-test a fresh consumer package that depends on the tag by URL and version.
