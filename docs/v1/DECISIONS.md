# Decisions

Newest last. Each entry: what was decided, why.

## D1. Link moves from v0.4.4 to the tag v1.0.8
`Cargo.toml` pins `arcade-link` `v1.0.8`; `scripts/sync-design.py` copied the design kit at the tag, and
`scripts/VENDORED` names it for the shared installer and shortcut assets (byte-identical to the earlier copies).
Why: the fleet rule "One launcher per app". 1.0.7's installer retires the old `dev.arcade.clipboard` launcher and
login item on update. 1.0.8 adds the compact key chips (RD-CLIPBOARD-2), the colour-emoji fallback (CB-10) and the
`windows-installer: inno` input that `release.yml` and `promote.yml` use.

## D2. The release manifest script goes; Link's publish writes the manifest (untangle)
`scripts/arcade-release.py` was a vendored copy of Link's manifest writer at `76883b3`, kept in step with Link by a
checksum. Since step 6, Link's reusable `app-publish.yml` writes `arcade-release.json` and `SHA256SUMS.txt` from the
built packages, so nothing ran the copy. It only had to be kept in step with Link's (a hidden link with no user). It
is removed, along with its checksum, its `.gitattributes` line and the manual command in `docs/dev/releases.md`.
