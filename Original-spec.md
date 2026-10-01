Do not treat this as a prototype, hackathon demo, AI wrapper, or UI mockup.

Build a genuinely useful, polished consumer application.

PROJECT

Working name:

Arcade Clipboard

The name is temporary and should not influence architecture.

The product is a cross-platform clipboard mesh connecting a user’s devices:

* Windows
* Linux
* macOS
* Android
* iPhone
* iPad

The fundamental idea is extremely simple:

Pair your devices once. From then on, anything intentionally added to your shared clipboard becomes available across the entire device mesh.

The application should feel like infrastructure rather than a messaging application.

There should be:

* no chat interface
* no “send message” mentality
* no complicated device-picker every time
* no accounts required for the basic experience
* no constant manual IP configuration
* no ugly enterprise-looking synchronization UI

The user pairs devices once and mostly forgets the application exists.

⸻

CORE PRODUCT PHILOSOPHY

Do not force one language/framework onto components where it performs poorly.

At the same time, do not build six unrelated native applications.

The intended architecture is:

Flutter first. Rust where it provides real systems-level value. Native platform code only where necessary.

The majority of the visible consumer application should share one Flutter codebase.

Use native code only for features that cannot be implemented cleanly, reliably, efficiently, or officially through Flutter alone.

⸻

HIGH-LEVEL ARCHITECTURE

Use this conceptual architecture:

                    UNIVERSAL CLIPBOARD
                         Flutter App
                ┌─────────────────────────┐
                │ Onboarding              │
                │ Device management       │
                │ Clipboard history       │
                │ Settings                │
                │ Search                  │
                │ Pairing UI              │
                │ Privacy controls        │
                │ Status / diagnostics    │
                └────────────┬────────────┘
                             │
                       Flutter ↔ Rust
                             │
                ┌────────────▼────────────┐
                │       Rust Core         │
                │                         │
                │ Device identities       │
                │ Pairing protocol        │
                │ Encryption              │
                │ Sync protocol           │
                │ LAN discovery           │
                │ Relay transport         │
                │ Deduplication           │
                │ Loop prevention         │
                │ Clipboard item model    │
                │ File transfer           │
                │ Compression             │
                │ Hashing                 │
                │ Connection state        │
                └────────────┬────────────┘
                             │
               ┌─────────────┼──────────────┐
               │             │              │
           Windows         macOS          Linux
          integration    integration    integration
               ┌─────────────┴──────────────┐
               │                            │
              iOS                        Android
       native extensions             native integrations

Do not unnecessarily duplicate networking, cryptography, protocol, synchronization, or data-format logic across platforms.

⸻

TECHNOLOGY DIRECTION

Main application

Use:

Flutter / Dart

for the primary application on supported platforms.

Flutter should own:

* primary UI
* onboarding
* device list
* history browser
* search
* settings
* pairing screens
* privacy controls
* status UI
* diagnostics
* most general application logic

Use a modern, maintained state-management architecture.

Do not introduce excessive architectural ceremony.

⸻

SHARED SYSTEMS CORE

Use:

Rust

for systems-level functionality where it makes sense.

The Rust core should preferably own:

* networking
* device identity
* cryptographic operations
* pairing protocol
* sync protocol
* LAN peer discovery
* remote relay communication
* reconnection
* item serialization
* deduplication
* origin tracking
* synchronization loop prevention
* content hashing
* compression
* file-transfer streams
* connection state
* protocol versioning

Choose a proven Flutter/Rust bridge rather than inventing an FFI system.

Verify current stable library compatibility before committing to dependencies.

⸻

NATIVE CODE

Native code exists only where Flutter cannot provide an equally good solution.

Examples:

iOS / iPadOS

Swift / UIKit / SwiftUI where appropriate for:

* Share Extension
* Keyboard Extension
* App Group integration
* system lifecycle integration
* officially supported background capabilities
* platform-specific pasteboard functionality

Android

Kotlin where required for:

* Android Share Target
* IME / keyboard integration
* foreground/background services where legitimately required
* Android clipboard/platform hooks
* platform lifecycle integration

Windows

Small native/platform integration layer where necessary for:

* global shortcut
* clipboard monitoring
* focus restoration
* overlay window behavior
* native clipboard formats
* pasting into previous application
* startup/background behavior

Do not rewrite the whole app in C#.

macOS

Small Swift/AppKit integration where required for:

* global shortcut
* NSPasteboard
* overlay/window behavior
* focus restoration
* native paste behavior
* menu bar/background integration

Linux

Native/system integration where necessary for:

* Wayland
* X11
* clipboard protocols
* global shortcuts
* focused-window handling
* desktop overlay behavior

Account for Wayland security restrictions instead of assuming X11 behavior.

The Linux implementation must be designed correctly for modern Wayland desktops.

⸻

IMPORTANT DESKTOP UX CHANGE

Do not implement the product as:

Copy on PC A
→ automatically replace PC B's normal clipboard
→ Ctrl+V on PC B

That can become annoying and can unexpectedly destroy a user’s local clipboard state.

Instead, create a separate concept:

THE MESH CLIPBOARD

Anything copied/shared into Universal Clipboard enters a synchronized Mesh Clipboard History.

Remote clips do NOT constantly overwrite the receiving computer’s active OS clipboard.

The user accesses the mesh using our own global shortcut.

The experience should be inspired by the interaction model of Windows Win+V clipboard history, but visually original and significantly more polished.

⸻

DESKTOP MESH CLIPBOARD OVERLAY

On Windows, macOS, and Linux, Universal Clipboard must provide a global configurable shortcut.

When pressed:

previously focused app
        ↓
global shortcut
        ↓
Universal Clipboard overlay appears
        ↓
↑ / ↓ choose item
        ↓
ENTER
        ↓
overlay disappears
        ↓
focus returns to previous application
        ↓
selected content is pasted automatically
into the field/app that had focus

The user should NOT then need to manually press Ctrl+V / Cmd+V.

The application may internally use the native clipboard and paste mechanisms if that is the safest/reliable platform implementation, but this must be invisible to the user.

The UX requirement is:

Shortcut → choose → Enter → pasted.

⸻

SHORTCUT

Do not permanently steal a hardcoded system shortcut.

Provide a sensible default appropriate to each OS, but make it completely configurable.

The user must be able to assign their own combination.

Detect obvious shortcut conflicts where possible.

The settings UI should provide a simple:

Mesh Clipboard Shortcut

control.

⸻

OVERLAY DESIGN

This overlay is one of the most important parts of the entire product.

It should feel:

* instant
* extremely lightweight
* premium
* minimal
* calm
* modern
* polished
* keyboard-first

NOT:

* a giant Flutter dialog
* a settings panel
* a full application window
* a command palette clone
* cluttered
* gamer-looking
* overly animated
* covered in gradients
* loaded with unnecessary controls

Think:

Windows clipboard history concept + premium modern desktop interaction design.

Possible structure:

┌───────────────────────────────────┐
│ Mesh Clipboard                 🔎 │
├───────────────────────────────────┤
│ ▣  Screenshot                     │
│    iPhone • 8 sec ago             │
├───────────────────────────────────┤
│ 🔗 github.com/...                  │
│    Linux PC • 24 sec ago          │
├───────────────────────────────────┤
│ T  ssh user@server                │
│    Windows PC • 1 min ago         │
├───────────────────────────────────┤
│ T  Longer copied paragraph...     │
│    MacBook • 3 min ago            │
└───────────────────────────────────┘

This is conceptual, not a mandatory visual design.

Use good judgment.

⸻

OVERLAY INTERACTION

Mandatory:

* global shortcut opens it
* selected item immediately visible
* Up/Down changes selection
* Enter pastes
* Esc dismisses
* mouse selection works
* clicking an item pastes it
* smooth scrolling
* recent item initially selected
* opening/closing feels instantaneous
* previous application focus is correctly restored

Strongly consider:

* typing while overlay is open starts searching
* subtle search mode
* Home/End navigation
* pinned clips
* device filter
* content-type filter

But never sacrifice simplicity.

⸻

OVERLAY POSITIONING

Prefer positioning near the current interaction context where reliable.

For example:

* near current caret
* near focused window
* near cursor

If platform limitations make that unreliable, use a predictable compact screen position.

Never make the overlay jump around unpredictably.

⸻

VISUAL DESIGN

The entire application needs a minimal premium consumer UI.

No bullshit.

Do not use excessive:

* cards
* borders
* giant headers
* nested settings pages
* gradients
* glass everywhere
* meaningless dashboards
* huge empty spaces
* icon overload
* animations for their own sake

Use:

* excellent spacing
* clear hierarchy
* restrained typography
* subtle depth
* tasteful translucency where appropriate
* good motion
* beautiful empty states
* high-quality icons
* platform-aware window behavior
* proper hover/focus states
* native-feeling keyboard navigation

Animations should generally be short and functional.

Approximately 120–220 ms is appropriate for most micro-interactions unless another duration feels materially better.

Respect reduced-motion preferences.

Support light/dark mode properly.

⸻

MAIN DESKTOP/MOBILE APP

Keep navigation minimal.

Likely primary sections:

1. Clipboard
2. Devices
3. Settings

Do not create ten navigation destinations.

⸻

CLIPBOARD SCREEN

Show synchronized history.

Each item should understand its content type.

Examples:

* text
* URL
* rich text
* image
* file
* group of files

Useful metadata:

* preview
* source device
* timestamp
* content type
* size where relevant
* pinned status

Allow:

* search
* copy locally
* delete
* pin
* inspect
* resend/re-share where appropriate

Avoid exposing protocol/internal metadata.

⸻

DEVICE MESH

Users should think in terms of one group of trusted devices.

Example:

My Devices
● Desktop
  Windows
  Online
● Laptop
  Linux
  Online
○ iPhone
  iOS
  Last seen 6 min ago

Keep it visually simple.

⸻

ONE-TIME PAIRING

This is a core experience.

The user should not manually configure:

* IP addresses
* ports
* cryptographic keys
* server addresses
* tokens

Normal pairing flow:

First device

Welcome to Universal Clipboard
[ Create Device Mesh ]
[ Join Existing Mesh ]

Create Mesh:

* generate device identity
* create mesh identity/keys
* name current device
* establish local configuration

Then offer:

Add Another Device

Show a QR code.

⸻

QR CODE PAIRING

Additional device:

Install Universal Clipboard
        ↓
Join Existing Mesh
        ↓
Scan QR
        ↓
verify device / handshake
        ↓
paired

The QR code should contain only what is necessary to bootstrap a secure pairing handshake.

Never encode long-term private secrets directly into a QR code.

Use an ephemeral pairing session.

The QR should preferably bootstrap:

* temporary rendezvous information
* ephemeral public key / pairing information
* mesh identifier
* short-lived authorization information

Then complete the secure exchange through the protocol.

After successful pairing:

* device creates its own long-term identity
* trusted membership is established
* required encrypted group/session keys are provisioned securely

Pairing tokens should expire.

Prevent QR replay.

⸻

HUMAN VERIFICATION

For additional protection, strongly consider showing a short verification fingerprint on both devices during pairing.

Example:

Desktop
BLUE • TIGER • 482
iPhone
BLUE • TIGER • 482

or a short numeric code.

Do not burden normal users with cryptographic terminology.

⸻

DEVICE REMOVAL

Removing a device must actually revoke it.

Do not simply hide it from UI.

On revocation:

* mark device untrusted
* prevent new synchronization
* rotate relevant shared/group secrets where necessary
* ensure revoked device cannot continue decrypting future clipboard entries

Design this properly.

⸻

NO ACCOUNT REQUIRED FOR MVP

The normal system should work without requiring:

* Google login
* Apple login
* email/password
* phone number

Identity should be device/mesh based.

Accounts could theoretically be an optional future convenience layer, but they are not part of the fundamental architecture.

⸻

NETWORKING MODEL

Prefer direct device-to-device communication whenever possible.

Order of preference conceptually:

Same LAN
   ↓
Direct encrypted connection
Different networks / NAT / CGNAT
   ↓
Encrypted relay

The system must work for users behind CGNAT.

Do not require port forwarding.

⸻

LOCAL DISCOVERY

Implement safe local peer discovery.

Candidate technologies may include mDNS/DNS-SD or another proven approach.

Do not invent a fragile discovery protocol if an established solution works.

Devices already belonging to the same mesh should recognize one another securely.

Discovery itself must not become an authentication mechanism.

⸻

REMOTE RELAY

Provide a small relay service for devices unable to connect directly.

The relay is transport infrastructure, NOT a trusted clipboard database.

It should not be able to read clipboard payloads.

The relay may know only the minimum metadata required for routing and operating the service.

Payloads must be encrypted end-to-end before reaching it.

Architect it so the relay could later be self-hosted, even if that is not a first-release UI feature.

Keep the relay architecture simple.

Do not create unnecessary microservices.

A single well-designed service is preferable.

⸻

OFFLINE DEVICES

Support short offline periods.

If Device B is offline when Device A adds a clipboard item:

* encrypted pending items may be temporarily queued
* Device B should receive them when reconnecting
* apply configurable retention limits
* avoid creating an infinite cloud clipboard archive

The relay should only ever store ciphertext.

⸻

SECURITY

Security matters heavily because clipboard content can contain sensitive information.

Do not invent custom cryptography.

Use established, audited primitives and maintained libraries.

The exact primitive selection should be documented and justified.

A reasonable design may involve:

* modern public-key identity
* secure authenticated key exchange
* authenticated encryption
* per-device identities
* forward-looking key rotation strategy

Evaluate established protocols/libraries such as Noise-style patterns or equivalent vetted approaches instead of designing crypto casually.

⸻

END-TO-END ENCRYPTION

Clipboard contents must be encrypted before leaving the originating trusted application/device.

Relay compromise must not expose clipboard plaintext.

Transport TLS alone is insufficient.

Use actual application-layer end-to-end encryption.

⸻

LOCAL KEY STORAGE

Private identity keys should use platform secure storage wherever possible:

* Windows secure credential/key storage
* macOS/iOS Keychain
* Android Keystore
* Linux secure secret-store integration where available

Handle systems without an available secure store gracefully.

Never store private keys in plain JSON configuration.

⸻

CLIPBOARD DATA MODEL

Design a versioned clipboard item format.

Conceptually:

ClipboardItem
id
protocol_version
origin_device
created_at
content_types[]
preview
payload references
content hash
size
expiration
metadata

Possible payload types:

text/plain
text/html
text/uri-list
image/png
image/jpeg
application/file-list

Preserve multiple compatible representations when useful.

Example:

A browser copy might contain both:

* plain text
* HTML

Do not unnecessarily destroy rich clipboard formats.

⸻

LOOP PREVENTION

This is critical.

Example bad behavior:

PC A copies item
→ PC B receives it
→ PC B clipboard watcher sees "new" clipboard
→ sends it to A
→ A sees it as new
→ infinite loop

Every synchronized item needs stable provenance/origin information.

Use:

* stable clip IDs
* content hashes where useful
* origin device
* seen-item tracking
* protocol-level deduplication

Test this heavily.

⸻

IMPORTANT CLIPBOARD BEHAVIOR

Receiving a remote item should not automatically replace the active local desktop clipboard.

Remote items enter the Mesh Clipboard History.

They become active/pasted only when the user chooses them.

This prevents:

* destroying local clipboard contents
* surprise pastes
* device fights
* clipboard oscillation

⸻

DESKTOP COPY BEHAVIOR

On desktop, normal copy behavior remains normal.

The user can still use:

Ctrl+C
Cmd+C
application Copy menu

The Universal Clipboard background component watches supported clipboard changes.

A normal local copy can be automatically added to the user’s Mesh Clipboard according to privacy/settings rules.

Then other trusted devices receive it in their Mesh Clipboard History.

⸻

MOBILE IS DIFFERENT

Do not fight mobile operating-system privacy restrictions.

Do not implement hacks intended to secretly scrape the mobile clipboard continuously.

Use mobile-native user initiated flows.

⸻

MOBILE → MESH

The primary outgoing mobile workflow should be:

Select something
      ↓
Share
      ↓
Universal Clipboard
      ↓
Add to Mesh Clipboard

Examples:

iPhone

Safari
Select text
Share
Universal Clipboard
Done

Android

Gallery
Share
Universal Clipboard
Done

The shared item should then become available across the user’s trusted mesh.

Do NOT force the user to choose Desktop/Laptop/iPhone each time.

The destination is:

the mesh

not an individual device.

Device-specific sending can exist later as an advanced option.

⸻

MOBILE SHARE EXTENSIONS

iOS:

Use a native Share Extension.

Android:

Use a native Android Share Target.

Support relevant content:

* text
* URLs
* images
* files where practical

The operation should be extremely quick.

Provide lightweight confirmation and dismiss.

Do not open the entire main application unless necessary.

⸻

MOBILE RECEIVING EXPERIENCE

The best way to use shared clipboard history while typing on mobile is a dedicated secondary keyboard.

Do NOT attempt to replace:

* Apple Keyboard
* Gboard
* Samsung Keyboard
* SwiftKey

Building autocorrect, swipe typing, predictions, multilingual input, dictation, etc. is not the goal.

Instead create:

UNIVERSAL CLIPBOARD KEYBOARD

This is a clipboard browser presented as a keyboard.

The user switches keyboards using the normal OS keyboard-switch mechanism.

Conceptually:

┌─────────────────────────────────┐
│ Search clipboard                │
├─────────────────────────────────┤
│ Desktop • now                   │
│ git clone https://...           │
├─────────────────────────────────┤
│ Laptop • 12 sec ago             │
│ Long paragraph preview...       │
├─────────────────────────────────┤
│ 📌 Wi-Fi password note          │
├─────────────────────────────────┤
│ Recent        Pins        Search│
└─────────────────────────────────┘

Tap a compatible text item:

insert it directly into the currently focused text field.

No:

open Universal Clipboard
copy
switch app
paste

Instead:

switch keyboard
tap item
done

⸻

IOS KEYBOARD

Implement the keyboard extension using the officially supported iOS custom keyboard APIs.

Use native Swift/UIKit where required.

The keyboard should:

* display synchronized items
* search clips
* show source device
* show useful previews
* insert text directly where allowed
* provide the required next-keyboard/globe behavior
* return to previous keyboard quickly

Use App Groups/shared storage appropriately between:

* main application
* Share Extension
* Keyboard Extension

Respect iOS restrictions.

Secure fields and applications that disable third-party keyboards should gracefully fall back to system behavior.

Do not try to bypass these restrictions.

⸻

ANDROID KEYBOARD

Implement a native Android IME where necessary.

Use Kotlin.

It should provide the same conceptual Clipboard Keyboard experience.

Use official InputConnection APIs.

Text clips should insert directly.

For supported receiving applications, investigate official rich-content keyboard APIs for:

* images
* compatible rich content

Fallback gracefully when a target application cannot receive a certain type.

⸻

IMAGES ON MOBILE

Do not promise universal image insertion into every mobile text field.

Platform/application support varies.

Handle capabilities properly.

If direct insertion isn’t supported:

* offer copy
* offer share
* or another clear fallback

Do not use hacks.

⸻

FILE SUPPORT

Support files progressively.

Do not let file-transfer complexity block a high-quality text/image MVP.

Recommended phases:

MVP

* plain text
* URLs
* desktop clipboard monitoring
* desktop Mesh Clipboard overlay
* pairing
* QR code joining
* device mesh
* LAN synchronization
* remote relay
* E2EE
* history
* search
* iOS Share Extension
* Android Share Target
* mobile clipboard keyboard for text
* proper reconnect/deduplication

Next

* images
* thumbnails
* rich text / HTML
* pins
* retention controls
* better offline queue

Later

* individual files
* multiple files
* folders
* resumable transfer
* advanced rich content
* optional self-hosted relay configuration

Architect the protocol from the beginning so these types can be added cleanly without breaking compatibility.

⸻

FILE TRANSFER EXPERIENCE

Eventually this should enable interactions such as:

Copy file on Windows
      ↓
Mesh receives file reference/content
      ↓
Open Mesh Clipboard on Linux
      ↓
select item
      ↓
paste into Nautilus

Use chunked/resumable transfer rather than loading giant files entirely into memory.

Large payload transfer should use streaming.

⸻

SEARCH

Clipboard search must feel instant.

Search useful fields:

* plain text
* URLs
* file names
* source device
* content type

Do not introduce embeddings/AI.

This is a deterministic utility.

Use an appropriate local index/SQLite FTS solution.

⸻

HISTORY

Clipboard history needs configurable retention.

Possible controls:

Keep history:
• 1 hour
• 24 hours
• 7 days
• 30 days
• Until deleted

Also support:

* maximum item count
* maximum object size
* optional per-type limits

Choose sensible defaults.

⸻

SENSITIVE CONTENT

Provide privacy controls.

Examples:

* temporarily pause capture
* temporarily pause sync
* exclude selected applications
* automatically expire certain clips
* maximum synchronized item size
* clear all shared history
* clear local history
* remove individual item

Investigate reliable detection/exclusion possibilities for:

* password managers
* secure clipboard flags
* private/secret clipboard formats

Do not pretend detection is perfect.

When the OS provides sensitivity metadata, respect it.

⸻

PRIVATE MODE

Provide an easily accessible temporary:

Pause Mesh

or

Private Mode

While active:

* local clipboard continues behaving normally
* Universal Clipboard stops adding new items to the mesh

Make state obvious without being intrusive.

⸻

PINNED CLIPS

Support pinning common snippets eventually.

Examples:

* email address
* SSH command
* phone number
* frequently used URL
* boilerplate

Pinned clips should stay at the top or in a dedicated minimal section.

They should still remain encrypted and synchronized.

⸻

DEVICE PRESENCE

Show useful states:

* Online
* Connecting
* Offline
* Last seen
* Removed

Do not expose unnecessary networking details in normal UI.

Diagnostics may expose them separately.

⸻

ERROR HANDLING

Consumer errors must be understandable.

Bad:

TransportError: rendezvous stream 0x0034 failed

Good:

Laptop is offline.
This item will sync when it reconnects.

Diagnostics can retain technical details.

⸻

CONNECTION RESILIENCE

The system must handle:

* Wi-Fi changes
* sleep/wake
* VPN changes
* switching LAN ↔ mobile hotspot
* relay reconnection
* app restart
* suspended laptops
* temporary internet loss
* changing IP addresses

without requiring re-pairing.

⸻

PERFORMANCE TARGETS

The product should feel instantaneous.

For small text items on LAN, synchronization should typically feel effectively immediate.

Optimize for:

* low idle CPU
* low idle RAM
* minimal wakeups
* low network chatter
* fast overlay launch
* fast search
* fast app startup

Do not poll aggressively.

Use event-driven architecture.

⸻

BACKGROUND BEHAVIOR

Desktop application should optionally start with the OS.

The background component should not require the main UI window to remain open.

Closing the main window should not necessarily kill clipboard synchronization if background mode is enabled.

Make this behavior clear.

⸻

OVERLAY IMPLEMENTATION DETAIL

The overlay requires platform-specific care.

When opened:

1. Record previously focused application/window.
2. Display overlay without causing destructive focus behavior.
3. Let user navigate.
4. User selects clip.
5. Hide overlay.
6. Restore the original target application.
7. Prepare selected payload using appropriate native clipboard/paste APIs.
8. Trigger paste/insertion using the safest officially supported mechanism.
9. Preserve or restore local clipboard state when appropriate.

Investigate the best implementation per operating system.

Do not assume one strategy works universally.

⸻

LOCAL CLIPBOARD PRESERVATION

Because our mesh overlay is separate from the OS clipboard, selecting a remote item should ideally not permanently destroy the user’s current local clipboard.

Where technically reliable:

1. snapshot current local clipboard
2. temporarily place selected remote payload
3. paste it
4. restore previous local clipboard

Be extremely careful about timing and asynchronous applications.

If clipboard restoration causes reliability issues on a platform, prefer reliable pasting over clever restoration.

Document platform behavior.

⸻

DATA STORAGE

Use a durable local database such as SQLite where appropriate.

Design storage deliberately.

Likely entities:

devices
clipboard_items
clipboard_payloads
pins
sync_state
pending_transfers
settings

Use schema migrations.

Never make database schema depend directly on UI widgets.

⸻

PROTOCOL VERSIONING

The first version must already support protocol evolution.

Every message/item should have a protocol/schema version.

Plan for:

* older clients
* unknown fields
* future payload types
* capability negotiation

Devices should advertise capabilities.

Example:

supports:
text
html
png
files-v1
rich-input

Never assume every device supports every content type.

⸻

CONFLICT MODEL

Clipboard is mostly an append-only temporal stream.

Do not try to build Google Docs-style distributed conflict resolution.

Each item gets:

* unique ID
* origin
* timestamp
* ordering information

The history can converge across devices.

Design ordering robustly enough for clocks that are slightly wrong.

Use protocol sequencing/logical ordering where appropriate.

⸻

RELAY SECURITY

Assume the relay may someday be compromised.

An attacker controlling the relay should not gain clipboard plaintext.

Protect against:

* payload modification
* spoofed device messages
* replay attacks
* unauthorized mesh joining

Authenticate protocol messages.

⸻

RATE LIMITING / ABUSE

The relay should have sensible protection against:

* giant uploads
* connection floods
* pairing spam
* unbounded queues

Do not let this become an enterprise anti-abuse project, but basic protections are required.

⸻

QR SECURITY

Pairing QR sessions should:

* expire quickly
* be single-use
* not reveal private keys
* not grant indefinite access if photographed
* require successful cryptographic handshake

Consider explicit confirmation for unusually old or repeated pairing attempts.

⸻

UI DETAILS

The main application should feel like a polished consumer utility.

Possible home state:

Universal Clipboard
Clipboard
─────────────────────────────
From Desktop
git clone ...
12 sec ago
From iPhone
https://...
1 min ago
From Laptop
A longer text preview...
4 min ago

Don’t copy this literally.

Design something better if appropriate.

⸻

EMPTY STATE

An empty clipboard screen can simply explain:

Your shared clipboard is empty.
Copy something on a desktop
or share something to Universal Clipboard
from your phone.

No giant illustration required.

⸻

ONBOARDING

Keep onboarding short.

Ideal flow:

Welcome
   ↓
Create Mesh / Join Mesh
   ↓
Name Device
   ↓
Pair if needed
   ↓
Done

Explain features while the user performs setup.

Avoid seven-screen onboarding carousels.

⸻

DESKTOP FIRST-RUN

On desktop, onboarding should offer:

* enable background sync
* enable launch at login
* choose global mesh shortcut

Use sensible defaults.

Don’t bombard the user with fifteen permissions simultaneously.

Request permissions when context makes sense.

⸻

MOBILE FIRST-RUN

Explain two core actions:

SEND TO MESH
Share → Universal Clipboard
PASTE FROM MESH
Switch keyboard → Universal Clipboard

Guide the user through enabling the custom keyboard.

On iOS, clearly explain any Full Access permission only if it is actually required by the implementation.

Never use misleading wording about permissions.

⸻

ACCESSIBILITY

Support:

* keyboard navigation
* proper focus indicators
* screen readers
* dynamic text where applicable
* sufficient contrast
* reduced motion
* non-color-only state indicators

⸻

DO NOT ADD AI

There is no need for:

* LLMs
* embeddings
* semantic search
* automatic summaries
* AI organization
* AI classification

This project is valuable because the software itself is useful.

Keep it deterministic and reliable.

⸻

NO FEATURE BLOAT

Do not turn this into:

* AirDrop replacement + chat
* note-taking app
* automation platform
* cloud drive
* password manager
* messaging app
* remote desktop tool
* file manager

Everything should support the core goal:

Move clipboard content between your own devices effortlessly.

⸻

REPOSITORY STRUCTURE

Design a clean monorepo.

A reasonable conceptual structure:

/apps
  /flutter_app
/core
  /rust
/platform
  /ios
  /android
  /windows
  /macos
  /linux
/services
  /relay
/docs
/tests

Do not follow this blindly if the build tooling suggests a cleaner structure.

The important part is clear boundaries.

⸻

DOCUMENTATION

Maintain at least:

README.md
docs/architecture.md
docs/protocol.md
docs/security.md
docs/platform-limitations.md
docs/development.md

Architecture documentation must reflect actual implementation, not hypothetical intentions.

⸻

DEVELOPMENT EXPERIENCE

Provide simple development commands.

I should be able to determine quickly:

* how to install dependencies
* how to run desktop client
* how to run relay
* how to run tests
* how to build each platform
* how to pair two local dev clients

Avoid fifteen manually coordinated terminals if one development script can simplify it.

⸻

TESTING

Testing is mandatory.

Rust core tests

Test:

* encryption/decryption
* device authentication
* item serialization
* protocol compatibility
* deduplication
* sync-loop prevention
* reconnect behavior
* offline queues
* item expiry
* revoked devices
* malformed payloads
* large payload boundaries

Flutter tests

Test:

* onboarding state
* device-management state
* clipboard-history state
* search
* settings persistence
* error states

Desktop integration tests

Where feasible test:

* clipboard detection
* overlay invocation
* arrow navigation
* Enter paste
* Esc close
* focus restoration
* shortcut rebinding

End-to-end tests

At minimum:

Test 1

Device A copies text
Device B receives item
Device B opens overlay
Device B selects item
Enter
Text appears in previously focused editor

Test 2

Device A receives remote clip
Device A must NOT send it back as a new clip

Test 3

LAN disconnect
relay takeover/reconnect
sync continues

Test 4

Device offline
new clip created
device reconnects
clip arrives once

Test 5

Device revoked
new items are created
revoked device cannot decrypt them

Test 6

mobile Share Extension
→ mesh
→ desktop overlay
→ paste

Test 7

desktop copy
→ mesh
→ mobile keyboard
→ select text clip
→ inserts into active text field

⸻

CI

Create useful CI for:

* formatting
* linting
* Rust tests
* Flutter tests
* protocol tests
* supported desktop build checks where practical

Do not create a giant deployment pipeline before the product works.

⸻

OBSERVABILITY

Normal users should see simple states.

Developers need diagnostics.

Include optional diagnostic logging for:

* connection lifecycle
* peer discovery
* relay connection
* sync events
* retries
* protocol errors

Never log plaintext clipboard payloads by default.

Never log cryptographic secrets.

⸻

SECURITY REVIEW

Before considering the MVP complete, conduct a focused security audit of:

* pairing
* device trust
* relay assumptions
* E2EE
* key storage
* replay prevention
* revocation
* clipboard history storage
* sensitive logging
* Share Extension
* keyboard extension

Use a dedicated Luna agent for adversarial review.

Do not allow that agent to modify security-sensitive code without Astra reviewing the changes.

⸻

AGENT ORCHESTRATION

Use GPT-5.6 Luna at MAX reasoning effort for implementation workers.

Astra remains the sole architectural authority.

You may use up to approximately six concurrent Luna agents when useful.

Do not let multiple agents freely edit the same architectural files.

Suggested workstreams:

Luna 1 — Rust protocol/core

Own:

* data model
* synchronization
* identity
* encryption
* deduplication
* networking foundations

Luna 2 — Flutter product/UI

Own:

* app shell
* onboarding
* clipboard screen
* devices
* settings
* pairing UI
* premium visual system

Luna 3 — Desktop integrations

Own:

* global shortcut architecture
* clipboard monitoring
* overlay behavior
* previous-focus restoration
* paste path

Split per OS later if needed.

Luna 4 — iOS

Own:

* Share Extension
* Clipboard Keyboard
* App Group
* iOS lifecycle/platform integration

Luna 5 — Android

Own:

* Share Target
* IME Clipboard Keyboard
* lifecycle/background integration

Luna 6 — Relay / testing / security

Depending on current project phase:

* relay implementation
* integration tests
* adversarial testing
* performance testing
* protocol fuzzing/security review

You can run multiple waves of workers.

⸻

ORCHESTRATOR RULES

Astra must:

* inspect every major worker result
* reject poor architecture
* resolve conflicting implementations
* keep shared interfaces consistent
* prevent duplicated functionality
* review security-sensitive changes
* run integration tests itself
* own final merge/integration
* keep the app buildable
* avoid letting agents endlessly refactor one another’s code

Workers should get bounded tasks with explicit files/interfaces.

Do not tell six agents “build the app.”

⸻

IMPLEMENTATION STRATEGY

Do not attempt every platform simultaneously before proving the architecture.

Work vertically.

Recommended order:

FOUNDATION

Build:

* repository structure
* protocol model
* Rust core skeleton
* Flutter shell
* development tooling
* basic relay

FIRST REAL VERTICAL SLICE

Get this working between TWO desktop clients:

Pair via QR
      ↓
Copy text on Device A
      ↓
Encrypted synchronization
      ↓
Item appears in Device B history
      ↓
global shortcut
      ↓
overlay
      ↓
Enter
      ↓
paste into previous app

This is the first critical milestone.

It must actually work.

No mocked sync.

No fake QR pairing.

No hardcoded demo devices.

⸻

THEN

Add:

* reconnect
* offline behavior
* history/search
* relay transport
* third desktop OS
* mobile sharing
* mobile keyboard
* images
* remaining polish

⸻

MVP PRIORITY

Do not sacrifice a fantastic working core in order to claim 40 incomplete features.

A strong MVP with:

* two or three working desktop platforms
* real E2EE
* QR pairing
* LAN + relay
* beautiful overlay
* real paste
* history
* mobile Share Extension/Target
* mobile text keyboard

is better than six half-functional platform ports.

However, keep the architecture compatible with all target platforms from the beginning.

⸻

UI QUALITY BAR

Do not wait until the end to “make it pretty.”

The first usable build should already have:

* correct spacing
* typography
* animation
* keyboard navigation
* dark/light theme
* good empty/loading/error states

Do not create an ugly engineering UI and promise to redesign it later.

At the same time, do not spend days making fake screens while networking doesn’t work.

Build vertical slices with both functionality and presentation.

⸻

NO PLACEHOLDER IMPLEMENTATIONS

Avoid code such as:

TODO sync later
fakePairDevice()
mockClipboardItems
simulateConnection()

Mocks are acceptable inside tests and isolated UI previews.

They are not acceptable as the product implementation.

⸻

DEPENDENCY DISCIPLINE

Prefer:

* actively maintained
* widely used
* well-documented
* platform-compatible

dependencies.

Avoid adding libraries for trivial functionality.

Pin versions sensibly.

Review security-sensitive dependency choices.

⸻

PLATFORM LIMITATIONS

Document real OS restrictions clearly.

Do not conceal limitations with hacks.

Examples:

* iOS keyboard restrictions
* secure fields
* apps blocking third-party keyboards
* mobile background limitations
* Android clipboard privacy behavior
* Wayland restrictions
* rich-content compatibility

Build the best official experience available on each platform.

⸻

PRODUCT EXPERIENCE WE ARE AIMING FOR

Desktop → Desktop

Desktop A
Ctrl+C normally
            ↓ sync
Laptop B
custom mesh shortcut
┌─────────────────────┐
│ copied text         │
│ Desktop • just now  │
└─────────────────────┘
Enter
            ↓
immediately pasted into
the previously focused app

iPhone → Desktop

iPhone
Select / Share
Universal Clipboard
            ↓
Desktop mesh shortcut
            ↓
select item
            ↓
Enter
            ↓
pasted

Desktop → iPhone

Desktop
Ctrl+C
            ↓
iPhone
switch to Universal Clipboard keyboard
            ↓
tap clip
            ↓
inserted into active text field

This should become muscle memory.

⸻

EXPERIENCE PRINCIPLE

The app should never feel like:

“I need to transfer something.”

It should feel like:

“That thing I copied on another device is simply here.”

That is the product.

⸻

FIRST THING YOU SHOULD DO

Before making broad changes:

1. Inspect the repository if one already exists.
2. Read all current code and documentation.
3. Determine what can be retained.
4. Produce a concise architecture/implementation plan.
5. Define module boundaries.
6. Define the initial protocol.
7. Define the first vertical-slice milestone.
8. Assign bounded work to Luna agents.
9. Begin implementation immediately.

Do not spend the entire response planning.

Move into implementation.

⸻

WORKING STYLE

At meaningful checkpoints tell me:

* what now works
* what changed
* what is still incomplete
* exactly how I can run/test the current build

Get me a genuinely usable vertical-slice MVP early while continuing development afterward.

Do not hide broken functionality.

If something is incomplete, say exactly what remains.

⸻

DEFINITION OF FIRST SUCCESS

I should be able to run Universal Clipboard on two desktop machines and do this for real:

1. Create mesh on Machine A.
2. Display pairing QR.
3. Scan/join from Machine B.
4. Copy text normally on Machine A.
5. Machine B receives it.
6. Focus a text editor on Machine B.
7. Press my Universal Clipboard shortcut.
8. Mesh Clipboard overlay appears.
9. Use arrow keys to select the item.
10. Press Enter.
11. Overlay closes.
12. Original editor regains focus.
13. Text appears at the cursor.

All synchronization between the devices must be genuinely encrypted and use the real protocol.

Once that experience is excellent, expand outward.

⸻

FINAL QUALITY EXPECTATION

I want this to feel like a utility that could plausibly ship as a serious consumer product.

Prioritize, in this order:

1. reliability
2. security
3. interaction quality
4. synchronization correctness
5. performance
6. simplicity
7. visual polish
8. additional features

The implementation should be clean enough that adding another platform or clipboard type does not require redesigning the entire project.

Build the smallest architecture capable of doing this properly.

Do not overengineer.

Do not underengineer the parts that matter.

Do not deliver a concept.

Deliver the application. You have full control
Do not give me a half baked mvp for trying the broken application but don’t over engineer toooo like we are buiding version 1 so go accordingly
