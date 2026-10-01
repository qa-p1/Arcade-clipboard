# Mobile integration

Rust remains the authority for device trust and synchronized history. Native share/keyboard storage handles bounded local handoff only.

## iPhone and iPad

scripts/setup-ios.rb adds the main mobile channel, SharedStore and both extension targets to the Flutter Xcode project. Extensions embed under PlugIns, use matching version metadata and the group.dev.arcade.clipboard App Group.

The Share extension loads bounded text, URLs, HTML/RTF, images and file representations from NSItemProvider. It validates names/types/limits, saves using complete iOS Data Protection and dismisses with an honest pending-sync message. Flutter acknowledges a handoff only after Rust accepts it.

The Keyboard extension reads a bounded cache and normally works without Full Access; Full Access is declared only as a fallback for iOS versions that deny keyboards read access to the App Group, and the keyboard says so when a read fails. It supports recent/pinned text, source/time previews, internal search keys and the globe switch. Only the selected clip is inserted through textDocumentProxy; host document text is not collected.

Native NetService discovery publishes/browses _arcade-clip._tcp and reports candidate sockets to Rust. Rust validates trusted identity and authenticates the connection independently of Bonjour.

[IPA and signing](ios-install.md) explains the workflow and entitlements. Main-app suspension means fresh shares/cache updates may wait until it resumes.

## Android

The runner includes ShareTargetActivity, MeshClipboardIme, MobileChannel, CoreIdentityStore and a private URI-grant content provider. Keystore protects the Rust identity and encrypted handoff/cache. File/image export grants access only to the chosen receiving application.

The share target accepts text/URLs and bounded image/file groups. The IME inserts text with InputConnection. App image actions use clipboard/share fallback; universal rich insertion is not promised.

Android/Apple runtime acceptance must be performed on their respective devices. The local Android APK build is compilation evidence, not a complete IME/share acceptance result.
