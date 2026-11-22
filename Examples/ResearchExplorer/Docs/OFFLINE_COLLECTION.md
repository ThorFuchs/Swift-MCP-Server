# The Riverglass offline collection

Research Explorer ships a small, coherent **fictional** research collection so the app is fully usable
on first launch without a network. It is the default source; launching the app makes no request and
starts no listener. Source of truth: [RE-01 #33](https://github.com/ThorFuchs/Swift-MCP-Server/issues/33).

## Provenance and licence

- All text, names, places, dates, measurements and references are **original teaching data written for
  this repository**. Nothing is copied or adapted from Wikipedia, Wikimedia projects or any other source,
  and no real person, institution or instrument is described.
- Licence: Apache-2.0, like the rest of the example (`license` field: *Apache-2.0 (original fictional
  teaching text, Research Explorer)*).
- Every resource carries `fixture_kind: synthetic_normalized_example_not_upstream_payload` and is in the
  owned `wre-fixture-1` format — never a Wikimedia wire payload. Snapshots are marked `synthetic: true`
  and the UI labels every result and article *Fictional · Offline demo*.
- Reference links use the inert `fixture://riverglass/references/…` scheme; the app never opens them.
- `RiverglassCollectionTests.shippedFixturesAreOwnedFictionalDataWithoutWikimediaClaims` checks the
  file list, the synthetic marker, the licence and the absence of Wikipedia/Wikimedia/`http(s)` claims.

## Articles

| Candidate | Page | Revisions | Purpose |
| --- | --- | --- | --- |
| `fixture-observatory` | Riverglass Observatory | r1, r2 | Hub article; the prepared r2 edit; intentionally unresolved citation |
| `fixture-expedition` | Riverglass Expedition of 1928 | r1 | Nested route sections; a disputed reading with competing sources |
| `fixture-instrument` | Riverglass Meridian Circle | r1 | Instrument detail; a section citing nothing (valid empty list) |
| `fixture-observations` | Riverglass Tide-Star Observations | r1 | Data series with a table; documented data gaps |
| `fixture-lanterns` | Riverglass Lantern Survey | r1 | Reference metadata deliberately **absent** (`missing_references`) |

The articles cross-reference each other in their text and *See also* sections, and share one
consistent set of fictional sources (the society minutes, the instrument notes, the expedition journal,
the catalogue, the flood report). Search matches titles and a few owned keywords
(`telescope`, `ostmere`, `catalogue`, …) in a fixed order.

Load-time checks (`FixtureProvider.load`) reject the collection unless every advertised candidate has
an article with the same title and every article is reachable from search. The only candidate without
an article is `FixtureProvider.testOnlyNegativeCandidate`, which exists solely when a test passes
`includeTestOnlyNegativeCandidate: true`; shipped search never returns it.

Deliberate edge cases, each covered by tests:
- `ref-lost-ledger` (Observatory, *Calibration*) is cited but has no metadata in any revision: an
  unresolved citation, shown as such rather than dropped.
- The Lantern Survey supplies no reference list: reported as missing metadata, not an empty list.
- Meridian Circle *Later modifications* cites nothing: a valid empty reference list.

## Revisions and the prepared edit

The collection is published in editions. `r1` is the launch state. Edition `r2` publishes one prepared
upstream edit: the Observatory's *Telescope* section corrects the aperture from 2 to 2.1 metres and
cites a new source (`ref-remeasurement-1931`); every other section is byte-identical. Pages without an
r2 keep r1.

In the app (offline demo only), **Simulate an upstream edit** publishes edition r2. Any outline the user
already holds stays pinned to its exact `SnapshotID` (provider, project, page, revision, normalizer).
**Check for a newer revision** explicitly asks for the current revision and, for the selected section,
shows the pinned and the latest text side by side. Only **Switch reader to r2** moves the reader. An
expired pin is reported as `absent_snapshot`, never replaced by the latest revision.

The edition is state of the shared offline provider, so an MCP client of the local server sees the same
upstream change — just as a live wiki edit would be visible to every client.

## One-click tour

**Explore the offline collection** runs the predictable journey search *Riverglass* → open
*Riverglass Observatory* (r1) → read *Telescope* with its references, through the same `ResearchClient`
operations a user would trigger. The tour values live in `OfflineTour` and are pinned by tests. It is
unavailable for the Wikipedia source and never falls back from a live error to fictional data.

## Limits

The whole collection is about 31 KB, far inside `ExplorerLimits` (32 KiB per section read, 4 MiB per
fixture file, 300 s snapshot TTL, 16 cache entries). Each file is read once at startup with an
overflow-detecting bounded read and validated by `Normalizer.normalize`.
