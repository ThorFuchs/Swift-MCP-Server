# Third-party notices

## Swift-HTML (HTML parsing for the live Wikipedia normalizer)

Research Explorer parses Wikipedia's HTML only in `MediaWikiNormalizer`, through the public API of
[Swift-HTML](https://github.com/ThorFuchs/Swift-HTML) **0.2.0** (tag revision
`9e5922e19fb45d3c97c72a57cca58adb2f799c78`, pinned in `Package.resolved`). Swift-HTML's own code
is Apache-2.0.

Swift-HTML vendors the **source only** of SwiftSoup 2.14.4 (upstream commit
`8397a860c6955924b584c50c5265c6aac0970015`) as its internal `SwiftHTMLBackend` module, without
upstream tests or their webpage fixtures. Its provenance, upstream hashes and verification scripts are
documented in Swift-HTML's `Documentation/THIRD_PARTY.md`. That vendored code remains MIT-licensed,
so redistributions of this app must keep both notices:

- SwiftSoup / jsoup, MIT: complete unchanged text in [Docs/SwiftSoup-LICENSE.txt](Docs/SwiftSoup-LICENSE.txt)
- LRUCache (Nick Lockwood), MIT: complete unchanged text in [Docs/LRUCache-LICENSE.txt](Docs/LRUCache-LICENSE.txt)

Both texts are byte-identical to the copies Swift-HTML ships as SwiftPM resources
(`SwiftHTML_SwiftHTML.bundle/…/ThirdPartyLicenses/`), which every build of this app includes.

Research Explorer has **no direct dependency on the `scinfu/SwiftSoup` package** since RE-08 (#42);
it is not in the resolved dependency graph, and the built `research-explorer` and
`ResearchExplorerApp` binaries contain no `SwiftSoup` module symbols. These receipts are engineering
evidence, not a legal opinion; final artifact licence review belongs to RE-05 (#37).

## Content

Wikipedia response content retains its returned license and contributor attribution.
Captured Noether's theorem revision1380698337 reports CC BY-SA4.0.
Application source is Apache-2.0; it does not relicense Wikipedia content.
The fictional Riverglass collection is original Apache-2.0 teaching text (see Docs/OFFLINE_COLLECTION.md).
