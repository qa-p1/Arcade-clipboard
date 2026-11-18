#!/usr/bin/env python3
"""Write THIRD_PARTY_NOTICES.md: every third-party part that ships inside Arcade Clipboard, with its licence text.

  scripts/notices.py           # rewrite THIRD_PARTY_NOTICES.md
  scripts/notices.py --check   # fail if it is out of date (scripts/check flutter and CI run this)

Rust: the normal (non-dev, non-build) dependency graph of the shipped packages, `arcade_core` (the cdylib the Flutter
app loads) and `arcade-clipboard-launcher` (the AppImage entry point), for every target platform, from
`cargo metadata --locked`; each crate's own licence files from its source. C sources a crate builds into the binary
(SQLite from libsqlite3-sys, libdbus from libdbus-sys) are listed on their own. `services/relay` and `tests/driver`
are not shipped and not read.
Dart: the packages the app depends on, without dev dependencies (`dart pub deps --json`, so the Flutter SDK and
`flutter pub get` are needed), each with the LICENSE file in the pub cache that `.dart_tool/package_config.json`
points at. The Flutter framework and engine are listed as one component; the engine's own third-party code (Skia,
ICU, HarfBuzz, FreeType, ...) and every Dart package's licence are also compiled by `flutter build` into
`data/flutter_assets/NOTICES.Z`, which the app shows in Settings > Licences and which scripts/native-notices.py
checks is in the AppImage. Vendored code and assets: the vendored hotkey_manager_linux, the Inter typeface, the
Material Icons font, and the files copied from Arcade Link (recorded in scripts/VENDORED, version checked against
Cargo.toml). Native libraries of the Linux AppImage: packaging/linux/native/, recorded by scripts/native-notices.py
from a built image. Identical licence texts are printed once, with every component that uses them.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "THIRD_PARTY_NOTICES.md"
APP = ROOT / "apps" / "flutter_app"
SHIPPED = ("arcade_core", "arcade-clipboard-launcher")
STANDARD = ROOT / "scripts" / "licences"
PREFERRED = ("MIT", "Apache-2.0", "Zlib", "BSD-3-Clause", "BSL-1.0", "MPL-2.0", "Unlicense")
LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|notice|copyright)([-._].*)?$", re.I)
# Dart SDK packages: the Flutter component below covers them. Path packages the repository owns are first-party.
SDK_PACKAGES = ("flutter", "flutter_web_plugins", "sky_engine")
FIRST_PARTY = ("arcade_desktop_bridge",)


def normalized(text):
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def licence_texts(folder, declared=None):
    files = []
    if declared:
        files.append(folder / declared)
    if folder.is_dir():
        files += sorted(p for p in folder.iterdir() if p.is_file() and LICENCE_FILE.match(p.name))
        sub = folder / "LICENSES"
        if sub.is_dir():
            files += sorted(p for p in sub.iterdir() if p.is_file())
    seen, texts = set(), []
    for path in files:
        if path.resolve() in seen or not path.is_file():
            continue
        seen.add(path.resolve())
        text = normalized(path.read_text(encoding="utf-8", errors="replace"))
        if text:
            texts.append(text)
    return texts


def standard(name):
    return (STANDARD / f"{name}.txt").read_text(encoding="utf-8")


def checkout_root(folder):
    """The repository root of a git dependency (licence files usually live there, not in the crate's folder)."""
    for parent in folder.parents:
        if (parent / ".git").exists() or parent.parent.name == "checkouts":
            return parent
    return None


def standard_text(expression, authors, name):
    """The SPDX text of the first preferred licence the crate offers, with its authors as copyright holders."""
    offered = re.split(r"\s+OR\s+|/", expression or "")
    # "Apache-2.0 WITH LLVM-exception": the licence text, then the exception's.
    exceptions = dict(term.split(" WITH ", 1) for term in offered if " WITH " in term)
    offered += list(exceptions)
    for spdx in PREFERRED:
        if spdx in offered:
            holders = ", ".join(re.sub(r"\s*<[^>]*>", "", a) for a in authors) or f"the {name} developers"
            text = standard(spdx)
            text = re.sub(r"Copyright \(c\) <year> <(copyright holders|owner)>\.?", f"Copyright (c) {holders}", text)
            if spdx in exceptions:
                text += "\n\n" + standard(exceptions[spdx])
            return [normalized(f"{name} is offered under {expression}; it publishes no licence file, so the standard "
                               f"{spdx} text follows.\n\n{text}")]
    return []


def cargo_metadata():
    return json.loads(subprocess.run(
        ["cargo", "metadata", "--locked", "--format-version", "1", "--all-features"],
        cwd=ROOT, check=True, capture_output=True, text=True).stdout)


def rust_crates(meta):
    packages = {p["id"]: p for p in meta["packages"]}
    members = set(meta["workspace_members"])
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    todo = [i for i in members if packages[i]["name"] in SHIPPED]
    if len(todo) != len(SHIPPED):
        sys.exit(f"notices: expected workspace crates {SHIPPED}")
    reached = set()
    while todo:
        node = nodes[todo.pop()]
        for dep in node["deps"]:
            if any(k["kind"] is None for k in dep["dep_kinds"]) and dep["pkg"] not in reached:
                reached.add(dep["pkg"])
                todo.append(dep["pkg"])
    crates = []
    for pid in reached - members:
        p = packages[pid]
        folder = Path(p["manifest_path"]).parent
        texts = licence_texts(folder, p.get("license_file"))
        if not texts and p["source"] and p["source"].startswith("git+"):
            root = checkout_root(folder)
            texts = licence_texts(root) if root else []
        if not texts:
            texts = standard_text(p.get("license"), p.get("authors") or [], p["name"])
        crates.append({
            "label": f'{p["name"]} {p["version"]}',
            "licence": p.get("license") or ("see licence file" if p.get("license_file") else "unspecified"),
            "home": p.get("repository") or p.get("homepage") or "",
            "texts": texts,
            "name": p["name"],
            "folder": folder,
        })
    return crates


def bundled_c(crates):
    """C sources a crate compiles into the shipped binary, which the crate's own licence does not cover."""
    found = {c["name"]: c for c in crates}
    out = []
    sqlite = found.get("libsqlite3-sys")
    if sqlite:
        header = (sqlite["folder"] / "sqlite3" / "sqlite3.h").read_text(encoding="utf-8", errors="replace")
        version = re.search(r'#define SQLITE_VERSION\s+"([^"]+)"', header).group(1)
        blessing = re.search(r"\*\*\s+(The author disclaims copyright.*?)\n\*\*\n", header, re.S)
        if not blessing:
            sys.exit("notices: the SQLite blessing was not found in sqlite3.h")
        text = "\n".join(line.lstrip("* ").rstrip() for line in blessing.group(1).splitlines()).replace("\n\n", "\n")
        out.append({
            "label": f"SQLite {version} (built into arcade_core by libsqlite3-sys)",
            "licence": "Public domain", "home": "https://sqlite.org/",
            "texts": [normalized(f"SQLite is in the public domain. Its source says:\n\n{text}")],
        })
    dbus = found.get("libdbus-sys")
    if dbus:
        source = dbus["folder"] / "vendor" / "dbus"
        configure = (source / "configure.ac").read_text(encoding="utf-8", errors="replace")
        version = ".".join(re.search(rf"m4_define\(\[dbus_{part}_version\], \[(\d+)\]\)", configure).group(1)
                           for part in ("major", "minor", "micro"))
        out.append({
            "label": f"D-Bus {version} (libdbus, built into arcade_core by libdbus-sys; Linux only)",
            "licence": "AFL-2.1 OR GPL-2.0-or-later", "home": "https://www.freedesktop.org/wiki/Software/dbus/",
            "texts": licence_texts(source),
        })
    return out


def uri_path(uri, base):
    parsed = urlparse(uri)
    return Path(unquote(parsed.path)) if parsed.scheme == "file" else (base / unquote(uri)).resolve()


def classify(text):
    """The SPDX id a pub package's LICENSE file reads as, or 'see licence text'."""
    lower = text.lower()
    if "apache license" in lower and "version 2.0" in lower:
        return "Apache-2.0"
    if "redistribution and use in source and binary forms" in lower:
        return "BSD-3-Clause" if "neither the name" in lower or "the names of" in lower else "BSD-2-Clause"
    if "permission is hereby granted, free of charge" in lower:
        return "MIT"
    if "permission to use, copy, modify, and/or distribute" in lower:
        return "ISC"
    if "mozilla public license" in lower:
        return "MPL-2.0"
    return "see licence text"


def yaml_value(text, key):
    match = re.search(rf"^{key}:\s*['\"]?([^'\"\n]+)", text, re.M)
    return match.group(1).strip() if match else ""


def plugin_platforms(text):
    block = re.search(r"^    platforms:\n((?:      .*\n?)+)", text, re.M)
    if not block:
        return ""
    names = re.findall(r"^      ([a-z]+):", block.group(1), re.M)
    return ", ".join(sorted(names))


def dart_packages():
    dart = shutil.which("dart") or shutil.which("flutter")
    config = APP / ".dart_tool" / "package_config.json"
    if not dart or not config.is_file():
        sys.exit("notices: needs the Flutter SDK on PATH and `flutter pub get` run in apps/flutter_app")
    graph = json.loads(subprocess.run([dart, "pub", "deps", "--json"], cwd=APP, check=True, capture_output=True, text=True).stdout)
    packages = {p["name"]: p for p in graph["packages"]}
    # Not the root's `dependencies`: that list holds the dev dependencies too.
    todo, reached = list(packages[graph["root"]]["directDependencies"]), set()
    while todo:
        name = todo.pop()
        if name not in reached:
            reached.add(name)
            todo += packages[name]["dependencies"]
    locations = {p["name"]: uri_path(p["rootUri"], config.parent) for p in json.loads(config.read_text())["packages"]}
    out = []
    for name in sorted(reached - set(SDK_PACKAGES) - set(FIRST_PARTY)):
        info, folder = packages[name], locations[name]
        pubspec = (folder / "pubspec.yaml").read_text(encoding="utf-8", errors="replace")
        texts = licence_texts(folder)
        platforms = plugin_platforms(pubspec)
        home = yaml_value(pubspec, "repository") or yaml_value(pubspec, "homepage") or f"https://pub.dev/packages/{name}"
        vendored = info["source"] == "path"
        out.append({
            "label": f'{name} {info["version"]}' + (" (vendored and patched in this repository)" if vendored else "")
                     + (f" [plugin: {platforms}]" if platforms else ""),
            "licence": classify(texts[0]) if texts else "unspecified",
            "home": home,
            "texts": texts,
        })
    flutter = locations["flutter"].parent.parent
    return out, flutter


def flutter_component(flutter):
    version = (ROOT / ".flutter-version").read_text(encoding="utf-8").strip()
    sdk = (flutter / "version").read_text(encoding="utf-8").strip() if (flutter / "version").is_file() else ""
    if sdk and sdk != version:
        sys.exit(f"notices: the Flutter SDK is {sdk}, .flutter-version says {version}")
    texts = licence_texts(flutter, "LICENSE")
    if not texts:
        sys.exit(f"notices: no LICENSE in the Flutter SDK at {flutter}")
    return {
        "label": f"Flutter {version}: framework and engine (libflutter_linux_gtk.so, with the Dart runtime)",
        "licence": "BSD-3-Clause", "home": "https://flutter.dev/", "texts": texts[:1],
    }


def link_vendored(meta):
    """The Arcade Link files copied into this repository, with the version scripts/VENDORED records."""
    record = (ROOT / "scripts" / "VENDORED").read_text(encoding="utf-8")
    versions = set(re.findall(r"tag (v\d+\.\d+\.\d+) \(commit\s+([0-9a-f]{40})\)", record))
    if len(versions) != 1:
        sys.exit(f"notices: scripts/VENDORED names more than one Arcade Link version: {sorted(versions)}")
    tag, commit = versions.pop()
    pinned = re.search(r'^arcade-link = \{[^}]*tag = "([^"]+)"', (ROOT / "Cargo.toml").read_text(encoding="utf-8"), re.M)
    link = next(p for p in meta["packages"] if p["name"] == "arcade-link")
    if not pinned or pinned.group(1) != tag or not (link["source"] or "").endswith(commit):
        sys.exit(f"notices: scripts/VENDORED records Arcade Link {tag} ({commit[:7]}) but Cargo.toml and the lock "
                 f"use {pinned and pinned.group(1)} ({(link['source'] or '')[-7:]})")
    root = checkout_root(Path(link["manifest_path"]).parent)
    return {
        "label": f"Arcade Link {tag} ({commit[:7]}): installer and shortcut assets, design kit, Arcade icons, "
                 "arcade_trim.h (vendored, see scripts/VENDORED)",
        "licence": "MIT OR Apache-2.0", "home": "https://github.com/qa-p1/Arcade-Link",
        "texts": licence_texts(root),
    }


def native_packages():
    """The Ubuntu packages bundled in the Linux AppImage, as recorded by scripts/native-notices.py."""
    folder = ROOT / "packaging" / "linux" / "native"
    if not (folder / "packages.json").is_file():
        return []
    record = json.loads((folder / "packages.json").read_text(encoding="utf-8"))["packages"]
    return [{
        "label": f"{name} (Ubuntu package)",
        "home": f"https://launchpad.net/ubuntu/+source/{info['source']}",
        "texts": [normalized((folder / "copyright" / f"{name}.txt").read_text(encoding="utf-8", errors="replace"))],
    } for name, info in sorted(record.items())]


def packaging_components():
    """What the AppImage runtime says it contains (checked against the built image by scripts/native-notices.py)."""
    def holder(text, who):
        return normalized(text.replace("<year> <copyright holders>", f"the {who} authors"))

    mit, zlib, bsd3 = standard("MIT"), standard("Zlib"), standard("BSD-3-Clause")
    bsd2 = standard("BSD-2-Clause")
    lgpl = standard("LGPL-2.1")
    bsd3 = re.sub(r"Copyright \(c\) <year> <owner>\.?|Copyright \(c\) <year>, <owner>\.?", "Copyright (c) the zstd authors", bsd3)
    return [
        {"label": "AppImage type2-runtime (Linux AppImage)", "licence": "MIT",
         "home": "https://github.com/AppImage/type2-runtime", "texts": [holder(mit, "AppImage project")]},
        {"label": "musl libc (inside the AppImage runtime)", "licence": "MIT",
         "home": "https://musl.libc.org/", "texts": [holder(mit, "musl")]},
        {"label": "libfuse (inside the AppImage runtime, statically linked)", "licence": "LGPL-2.1-only",
         "home": "https://github.com/libfuse/libfuse", "texts": [normalized(lgpl)]},
        {"label": "squashfuse (inside the AppImage runtime)", "licence": "BSD-2-Clause",
         "home": "https://github.com/vasi/squashfuse",
         "texts": [normalized(bsd2.replace("<year> <owner>", "the squashfuse authors"))]},
        {"label": "libzstd (inside the AppImage runtime)", "licence": "BSD-3-Clause",
         "home": "https://github.com/facebook/zstd", "texts": [normalized(bsd3)]},
        {"label": "zlib (inside the AppImage runtime)", "licence": "Zlib",
         "home": "https://zlib.net/", "texts": [normalized(zlib.replace("<year> <copyright holders>", "the zlib authors"))]},
    ]


def render():
    meta = cargo_metadata()
    crates = rust_crates(meta)
    dart, flutter_root = dart_packages()
    mit_file = normalized((ROOT / "platform/desktop/vendor/hotkey_manager_linux/LICENSE").read_text(encoding="utf-8"))
    assets = [
        {"label": "Inter (typeface, assets/fonts/InterVariable.ttf)", "licence": "OFL-1.1", "home": "https://rsms.me/inter/",
         "texts": [normalized((APP / "assets" / "fonts" / "OFL.txt").read_text(encoding="utf-8"))]},
        {"label": "Material Icons (fonts/MaterialIcons-Regular.otf, added by `uses-material-design`)",
         "licence": "Apache-2.0", "home": "https://github.com/google/material-design-icons",
         "texts": [normalized(standard("Apache-2.0"))]},
        link_vendored(meta),
    ]
    vendored = [
        {"label": "hotkey_manager_linux 0.2.0, native part (platform/desktop/vendor/hotkey_manager_linux/linux)",
         "licence": "MIT", "home": "https://github.com/leanflutter/hotkey_manager", "texts": [mit_file]},
    ]
    sections = [
        ("Flutter", [flutter_component(flutter_root)]),
        ("Dart packages", dart),
        ("Rust crates", [{k: v for k, v in c.items() if k not in ("name", "folder")} for c in crates]),
        ("C code built into the Rust core", bundled_c(crates)),
        ("Vendored code", vendored),
        ("Fonts, icons and files copied from Arcade Link", assets),
        ("Packaging", packaging_components()),
    ]
    native = native_packages()
    missing = [c["label"] for _, group in sections for c in group if not c["texts"]]
    if missing:
        sys.exit("notices: no licence text found for " + ", ".join(sorted(missing)))
    unknown = [c["label"] for _, group in sections for c in group if c["licence"] == "see licence text"]

    lines = [
        "# Third-party notices",
        "",
        "Arcade Clipboard is licensed under the MIT licence (see `LICENSE`). It includes the open-source parts below, each",
        "under its own licence. This file is generated by `scripts/notices.py`; do not edit it by hand.",
        "",
        "Scope: the Rust crates and Dart packages are those of every target (Linux, Windows, macOS, iOS and Android),",
        "without dev dependencies; the native libraries and the packaging are those of the Linux AppImage and its",
        "tarball. The relay (`services/relay`) is a separate server you run yourself and is not part of the app; it is",
        "not listed. Windows, macOS, iOS and Android installers and the platform libraries they take from the operating",
        "system or from Gradle and CocoaPods (for example Google ML Kit in the mobile builds) are not covered here.",
        "",
        "The Flutter engine compiles the licences of its own third-party code (Skia, ICU, HarfBuzz, FreeType, ...) and of",
        "every Dart package into `data/flutter_assets/NOTICES.Z`. That file ships in the app (in the AppImage:",
        "`usr/lib/arcade-clipboard/data/flutter_assets/NOTICES.Z`) and **Settings > Licences** shows it.",
        "",
    ]
    by_text = {}
    for title, group in sections:
        lines += [f"## {title}", ""]
        for c in sorted(group, key=lambda c: c["label"].lower()):
            home = f" — {c['home']}" if c["home"] else ""
            lines.append(f"- {c['label']} ({c['licence']}){home}")
            for text in c["texts"]:
                by_text.setdefault(text, []).append(c["label"])
        lines.append("")
    if native:
        lines += [
            "## Native libraries in the Linux AppImage",
            "",
            "The Linux AppImage bundles these Ubuntu 24.04 packages' libraries next to the app (`usr/lib/arcade-clipboard/lib`).",
            "They are dynamically linked and stored as separate files: to use a modified version of an LGPL library, run",
            "the AppImage with `--appimage-extract`, replace the library in `squashfs-root/usr/lib/arcade-clipboard/lib`, and",
            "start `squashfs-root/AppRun`. The source of every version of each package is published by Ubuntu at the link",
            "given. The Flutter engine, the Rust core, the plugins and the launcher are listed above. GTK, GLib and the",
            "other libraries the app links are not bundled; the system provides them.",
            "",
        ]
        for c in native:
            lines.append(f"- {c['label']} — {c['home']}")
            for text in c["texts"]:
                by_text.setdefault(text, []).append(c["label"])
        lines.append("")
    if unknown:
        lines += ["## Licences to read in the text", "",
                  "The package's licence file is not one of the common ones, so read its text below: "
                  + ", ".join(sorted(unknown)) + ".", ""]
    lines += ["## Licence texts", ""]
    for n, (text, users) in enumerate(sorted(by_text.items(), key=lambda kv: (sorted(kv[1])[0].lower(), kv[0])), 1):
        users = sorted(set(users), key=str.lower)
        lines += [f"### {n}. Used by {', '.join(users)}", "", "```text", text.replace("```", "'''"), "```", ""]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="fail if THIRD_PARTY_NOTICES.md is out of date")
    args = ap.parse_args()
    text = render()
    if args.check:
        current = normalized(OUT.read_text(encoding="utf-8")) if OUT.exists() else ""
        if current != normalized(text):
            sys.exit("THIRD_PARTY_NOTICES.md is out of date: run scripts/notices.py")
        print("THIRD_PARTY_NOTICES.md is current")
        return
    OUT.write_text(text + "\n", encoding="utf-8", newline="\n")
    print(f"Wrote {OUT.name}: {len(text) // 1024} KiB")


if __name__ == "__main__":
    main()
