# Linux shortcut adapter patch

Vendored hotkey_manager_linux 0.2.0 (MIT), from leanflutter/hotkey_manager.
Kept API-compatible with the upstream plugin. Fixes undefined pointers on
unknown/unregistered shortcuts, propagates keybinder registration conflicts,
and corrects event ownership. Required by current Clang builds.
