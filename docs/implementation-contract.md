# Implementation contract

The UI speaks to a single asynchronous Flutter Rust Bridge JSON boundary. Requests include an operation name; results are typed maps/lists decoded by CoreApi. This boundary owns no separate cryptographic or synchronization implementation in Dart.

Rust operations cover lifecycle/status/change waits, mesh creation/invites/join/confirmation, history/payload/capture, pins/deletion/clear/resend, device management, settings and native discovery candidates. Invalid inputs return actionable errors. initialize/shutdown serialize against in-flight requests.

A successful remote receive changes durable mesh history and revision state only. OS clipboard writes occur through explicit copy/picker actions. Desktop capture is on by default and suppressed for explicit app clipboard writes to prevent recapture.

Mobile inbox entries are acknowledged after durable capture, never before. Keyboard publication uses unfiltered compatible recent history, not the app's current search. iOS native discovery is advisory; Rust trust checks still decide whether a candidate is usable.

Production screens use real state. Fakes are confined to tests/visual fixtures. Evidence and limitations are maintained in verification/checkpoint.md and platform-limitations.md.
