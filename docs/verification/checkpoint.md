# Verification checkpoint

Updated 2026-10-02. Results are from executed checks in this Linux workspace, not inferred from previous documentation.

- Rust core: 44 tests pass.
- Relay: 6 unit tests and 4 real WebSocket tests pass.
- Rust strict Clippy: passes.
- Flutter: 20 controller/widget/visual tests pass; analysis clean.
- Linux release bundle and relocatable archive: built.
- Android debug APK: previously built; runtime share/IME acceptance not completed.
- iOS: extension metadata/wiring updated and setup script applied; unsigned
  macOS/Xcode build is supplied through GitHub Actions. No completed iOS build
  or device acceptance is claimed by this local checkpoint.
- Windows/macOS: native source integration present; target build/runtime acceptance not performed here.

The separate Hyprland GUI acceptance run did not complete successfully. The
running app exposed an obsolete keyword command in a Lua configuration session.
Shortcut registration/cleanup and focus/paste now select the active provider,
using the current Lua API where required. The release bundle was rebuilt after
that fix. Further live tests were stopped at the user's request. Full picker
paste acceptance remains unverified after this change.

Docker/Caddy relay deployment code and startup instructions are included. No
public relay was deployed. The GitHub workflow validates iPhone executables,
embedded extension metadata and the Rust bridge before publishing its artifact.

Local ignored verification logs/screenshots are under .verification/. Source-only UI screenshot fixtures are isolated to tests. No fake devices/clips are shipped in the app.
