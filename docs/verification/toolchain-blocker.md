# Toolchain verification status

On 2026-09-30 the workspace-local Rust toolchain was installed and verified:

- Rust stable `1.98.1` (`rustc 1.98.1`, `cargo 1.98.1`)
- Flutter stable archive `3.47.5` with Dart `3.13.4`
- Flutter archive SHA-256 `2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb`, matching the official stable release metadata

Flutter CLI verification and runner generation are blocked in this execution
environment. Executing Flutter's bundled `flutter_tools.snapshot` triggered an
automatic approval review because it attempted an HTTP request to
`169.254.169.254`, the cloud metadata endpoint. The review rejected that
operation, stating that it may expose instance credentials or sensitive
metadata, and explicitly instructed us not to retry through a workaround or
indirect execution. No retry or bypass was attempted.

As a result, this workspace has not verified `flutter --version`, run
`flutter create`, generated the Flutter/Rust bridge, or run Flutter analyze,
tests, or desktop builds. A Dart SDK `--version` check succeeded, but does not
verify Flutter CLI operation. These checks must be completed in a trusted
development environment where Flutter can run without making a request to the
metadata endpoint. Do not describe generated runners, bridge bindings, or a
Flutter build as verified until then.
