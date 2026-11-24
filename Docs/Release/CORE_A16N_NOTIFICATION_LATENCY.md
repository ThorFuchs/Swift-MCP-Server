# A1.6n — catalog preparation latency and list-change notification

The B3 archive `core-a16e-b3-G9E4WjIv.tar.gz` SHA-256
`ce67eaca4d64b048901dd224a0887f7ac2cebae21f7557fdda540b0fafe9cbdc`
on HTTP diagnostic commit c99b65a9ee7879187e6d67e9771b8daa30115502
and Core 02958abee82c363b879aa013c38229edb9a1c116 contains a single SHOULD warning:
`sep-2575-server-sends-prompts-list-changed-on-subscription` in
`server-stateless` Debug. Release receives the actual notification with
subscription ID. Fixture stderr records the first prompt mutation as
9,801,559,000 ns total (24,330,417 construction, 9,777,216,333 preparation /
publication, 7,875 notification admission); Release 1,010,490,375 ns total.
The initial tool mutation similarly takes 9,790,852,125 ns Debug.
The logs do not establish the exact referee observation window, nor isolate
schema compilation from other preparation work or transport delivery.

Candidate: reuse only immutable previously admitted tool schema compiler
plans when their preserved serialized JSON bytes match, scoped to the
current snapshot of this one server. Cold preparation and changed schemas
still compile with the same default offline policy. New tool metadata,
name/scope/feature/provider/round plans, header inspection, extensions,
catalog generation and retained-weight accounting remain fresh. The new
budget pays both serializations, byte comparison and conservative plan
reference cost; no stored or manufactured compiler report. No global
application schema cache, no public API change, no notification reorder,
test masking or timeout changes. This is a candidate latency improvement,
not a proven explanation or fix for the historical warning.

Four focused source tests cover reuse and accounting, changed schema
validation, exhausted account, and new provider/scope/generation. Native
Swift 6.4.2 tests and full CI must pass. Then compare the same HTTP B3
fixture on baseline/candidate, fresh process per repetition, original
referee and observation windows; require actual prompt and tool
notifications, actual catalog mutations, correct IDs, zero failures and
zero target warnings across repeated Debug/Release runs. Measure mutation
preparation and publication times; retain failed runs. Do not merge a
candidate just because the old warning disappears once. A2/#29 separate.
