# RE-03 review screenshots

Rendered on macOS 27 (Mac Studio, Swift 6.4.2) by `ReaderSnapshotTests`, which hosts the app's real
`ExplorerRootView` (or, for 07/08, the evidence pane alone) in an on-screen window and renders its
layer tree to PNG:

```bash
RE_SNAPSHOT_DIR=/tmp/re03shots swift test --package-path Examples/ResearchExplorer --filter ReaderSnapshotTests
```

| File | Shows |
| --- | --- |
| 01-first-run-light | First launch: offline collection, one-click tour, no network and no server |
| 02-reader-wide-light | 1440 pt: outline · reading · evidence columns after the tour (r1, *Telescope*) |
| 03-reader-wide-dark | The same in dark appearance |
| 04-reader-compact-light | 900 pt: outline and evidence move to an inline bar (section menu, ↑ ↓, Evidence popover) |
| 05-reader-large-article-text-dark | Article text size 24 pt (Settings → Article text size) |
| 06-search-results-light | Five candidates, each with its *Fictional · Offline demo* source badge |
| 07-evidence-cited-light | Evidence pane: resolved reference, unresolved citation next to it, full provenance |
| 08-evidence-metadata-missing-dark | Evidence pane: reference metadata absent, stated as different from an empty list |

**Capture limits, not app defects:** window-server materials are not part of a window's layer tree,
so the workspace sidebar (Research/Server/Activity) renders blank and the selected outline row's
highlight renders as a solid bar. Toolbar overflow menus are not captured. Everything the app
draws itself is shown as rendered. macOS has no system Dynamic Type for these text styles; the
app's text-size control is the article text size setting shown in 05. Final packaged-app
screenshots with VoiceOver checks belong to RE-05 (#37).
