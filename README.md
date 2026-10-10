# swiftty

Swift 6.4 terminal core and frontends for macOS (AppKit) and iOS/iPadOS
(UIKit). `SwifttyCore` and `SwifttyMobile` also build for Mac Catalyst,
visionOS and tvOS. [spec.md](spec.md) defines scope, protocols and acceptance requirements.
[Shell](https://github.com/chr33s/shell) embeds the core through its libghostty API.

## Build and test

Requires Xcode 27 and the tools pinned in `mise.toml`:

```sh
mise install
mise run test       # unit tests and real PTY sessions: sh, vim, less, tmux, top
mise run app        # launch the macOS terminal
mise run bench      # Release microbenchmarks
mise run lint
mise run format
mise run format-check
mise run test-internal
mise run bench-storage
mise run compare <ghostty-src> <corpus-dir>
```

The package sets `SDKROOT` for swift.org toolchains. Build the UIKit frontend
with Xcode; the package's AppKit executable scheme is macOS-only:

```sh
xcodebuild -scheme SwifttyMobile -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme SwifttyMobile -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SwifttyMobile -configuration Release -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SwifttyMobile -configuration Release -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
```

Hosted mobile tests need XcodeGen and Python 3:

```sh
Scripts/test-ios-simulator.sh <simulator-udid>
Scripts/test-ipad-frame-time.sh <device-udid> <development-team>
```

Both scripts retain results in a temporary workspace and print its path. Physical
tests use existing signing profiles. Simulator GPU timings are indicative only.
Recorded `sh`, `vim`, `less`, `tmux` and `top` sessions live in
`Tests/SwifttyMobileTests/Fixtures`; regenerate with
`SWIFTTY_RECORD=1 swift test --filter SessionRecorder`.

## Embedding

On macOS, `TerminalSession.start(_:)` can launch a PTY child. External
transports feed program output through `receive(_:)`, send encoded input from
`onWrite`, and forward resize events to the remote program. Connection setup,
authentication and reconnection belong to the embedding app.

`TerminalUIView(session:configuration:fontSize:)` hosts a session. An iOS app
target can use `SwifttyMobileAppDelegate` and `SwifttyMobileSceneDelegate` for
the reference demo. No Xcode app project or network client is included.
visionOS omits accessory views, input clicks, haptics and screen-coordinate
keyboard avoidance. tvOS additionally omits the clipboard, edit menus,
pointer, hover, pinch, long-press and pan gestures: the focus engine can focus
the view, the select button makes it first responder, and hardware or system
keyboards provide input.

### Remote presentation and surface capabilities

`TerminalSession(presentationColumns:rows:configuration:)` creates a session
that displays frames produced by another, authoritative terminal (for example
a roaming host). It never parses program output or encodes input:
`installPresentation(_:)` validates a `PresentationFrame` and replaces the whole
screen atomically, keeping the frame's cell widths, graphemes and wraps without
reflow, and marks it fully damaged. `send` forwards committed text, key presses
and pastes to `semanticInputHandler` (never `onWrite`), `resize` proposes the
view's grid to `gridProposalHandler`, and history is disabled. Local selection
and copy work on the displayed frame.

Both frontends take a `capabilities: SurfaceCapabilities` (default `.full`;
`.roaming` for remote presentation). Program-initiated clipboard writes (OSC
52) reach the pasteboard only with `remoteClipboardWrites`. Without the
matching capability, link opening, search, scrollback, mouse reporting, paste,
copy and text input are hidden or disabled rather than shown as nonfunctional
controls; presentation sessions also disable local resets and raw-byte
bindings. On UIKit, `hidesContentWhenInactive` covers the terminal while its
scene is inactive or in the background, so app-switcher snapshots omit it.
Shell input disables autocorrection, capitalization, spell checking, smart
quotes, dashes and insert/delete, and inline prediction.

OSC 7501 is opt-in through `SessionConfiguration.programStatusEnabled` or
`setProgramStatusEnabled(_:)`. Read `programStatusSnapshot`, subscribe through
`onProgramStatusChange`, and route `onTerminalReply` to the originating transport.
External transports call `programExited()` when the program or connection ends.
The [program-status contract](spec.md#osc-7501-program-status) specifies validation,
lifecycle and reply provenance.

## SwiftMux

[spec.multiplexer.md](spec.multiplexer.md) describes a persistent session
service for Swiftty. A per-user LaunchAgent (`swiftmux-agent`) owns the shells,
PTYs, terminal engines, history and workspace layouts. Frontends connect to it
over one Mach/XPC endpoint using `SMX/1`: tagged JSON records that carry full,
validated pane frames.

- `swmux` is the terminal client. It runs only inside Swiftty
  (`TERM_PROGRAM=swiftty`, or pass `--allow-host`). Commands: `new`, `attach`,
  `list`, `detach`, `end`, `status`. The prefix is `C-b`; press `C-b ?` for the
  bindings. Settings live in `~/.config/swmux/settings.json`: `prefix`,
  `escapeDelayMilliseconds` and `remainOnExit`.
- The service links only `SwifttyEngine`: the parser, terminal state, history,
  input encoding and PTY code, with no Metal, fonts or AppKit. `SwifttyCore`
  re-exports the engine and adds the renderer, fonts and sessions.
- The Swiftty app's SwiftMux menu attaches a native window. Its panes render
  service frames directly through Metal. AppKit draws the tab strip (icons,
  titles, activity dots, double-click to rename), pane headers and draggable,
  VoiceOver-adjustable dividers. Shortcuts: ⌘T new tab, ⌘D / ⇧⌘D split,
  ⌥⌘arrows focus, ⌃⌘arrows resize, ⇧⌘↩ zoom, ⌥⌘W end pane, ⌃⌘W close tab.
  Ending a running pane or tab asks first. Find (⌘F, ⌘G, ⇧⌘G) searches the
  service-side history, and app theme changes update the colours panes
  report to programs. Quitting the app detaches; the shells
  keep running.
- Panes start through `swmux-launcher`, which calls `login_tty` and then execs
  the shell. They run with `TERM=swmux-256color`; the agent compiles that
  terminfo entry into `~/Library/Application Support/SwiftMux/terminfo`.

```sh
swift build
.build/debug/swmux agent install   # development LaunchAgent for this build
.build/debug/swmux new -s work     # inside Swiftty
Scripts/package-swiftmux.sh [identity]   # Swiftty.app with the bundled agent (SMAppService)
```

Acceptance evidence and measurements (`mise run bench-swiftmux`) are recorded
in section 11 of [spec.multiplexer.md](spec.multiplexer.md).

The service enforces the limits in `MuxLimits`: 32 panes, a 256 KiB input
buffer per pane, 16 MiB frames, 1 MiB pastes and a bounded history per pane.

### Deep links

Attention items (OSC 7501) can be opened from a link, as described in section 9
of `swiftty-unified-spec.md`:

```text
swiftty://attention/open?ref=<locator>
https://<configured domain>/a/<locator>
```

- `MuxNavigation` holds the typed `AttentionDestination`: the recipient's host
  profile ID, service epoch, workspace, tab, pane, terminal epoch, record path
  and incarnation, occurrence and intent (`review`, `result` or `reveal`). It
  also has the locator codec, link validation and `AttentionNavigator`, a
  state machine for the navigation steps. It needs only Foundation and builds
  for every platform, watchOS included. `MuxNavigationSMX` adapts the navigator
  to a local SwiftMux connection.
- The locator is a versioned binary record of IDs, encoded as base64url. It
  holds no endpoints, hostnames, usernames, credentials, message text or
  commands. **It is not an authentication credential.** The app resolves a
  link only against hosts the recipient has configured. If the host is
  unknown, the app asks the user to pick one. It never connects to anything
  named in the link.
- The app checks a link before it contacts anything. The scheme or configured
  domain must match, the link must be at most 2 KiB, the path must match, and
  the URL must have exactly one `ref` and no other parameters. The locator must
  decode strictly. The app then checks the service epoch and the exact
  occurrence before it shows any metadata. If the item is stale, superseded,
  missing or from before a service restart, the app says so and never shows a
  different request in its place. "Open in pane" attaches without taking over.
  If another client holds the workspace, the app asks for an explicit takeover
  tied to the lease generation the user saw. The app marks only the linked
  occurrence seen.
- On macOS, Swiftty handles the `swiftty` scheme (`CFBundleURLTypes`, written
  by `Scripts/package-swiftmux.sh`). It opens or activates the SwiftMux window
  and focuses the pane. Prompts appear as alerts. Universal Links stay off
  until `SWIFTTY_LINK_DOMAINS` is set when packaging.
- The roaming clients (iOS/iPadOS, Catalyst, visionOS, tvOS and the Mac
  client) register the scheme through `Apps/Config/AttentionLinks.plist`. They
  route `onOpenURL`, web-browsing activities and attention Handoff into a
  destination sheet. RST/1 does not carry attention data yet, so roaming hosts
  report "attention not yet available over roaming". Universal Links need
  `SWIFTTY_LINK_DOMAIN` and `Apps/Config/AssociatedDomains.entitlements.template`,
  which is not enabled. `links.example.invalid` is a placeholder only.
- The watch shows redacted `AttentionSummary` values: category, app name,
  counts and time. Message text is hidden by default. The watch can offer a
  Handoff (`AttentionHandoffRequest`) to a paired device, but it never takes a
  lease or sends input.

### Attention inbox

Every SwiftMux pane parses OSC 7501 program status (protocol revision 0.3),
whether or not it is shown, attached or leased. The service reduces each change
in stream order, then sends coalesced updates
([swiftty-unified-spec.md](swiftty-unified-spec.md) §8):

- `MuxAttention` is a pure reducer with three separate models: the current
  status of each record, **Needs you** occurrences (one per stretch of
  `blocked`), and the latest unreviewed failure and result of each source. A
  source is identified by service epoch, pane, terminal epoch (new after RIS),
  record path and record incarnation, never by program name or text. A fast
  `blocked → working → blocked` sequence produces two occurrences. `done →
  working` keeps the result. Prompts, process exit and `clear` resolve
  requests; silence never does.
- The SMX commands `subscribeInbox`, `inbox` (100 rows per page, opaque
  cursor), `locateAttention`, `markSeen`, `snooze` and `markReviewed` need no
  lease. They never resize panes and must match the occurrence exactly.
  Opening an item marks it seen but does not resolve it. Only failures and
  results can be reviewed. `locateAttention` reports whether another frontend
  holds the workspace lease.
- Limits: 64 records per pane, 16 MiB of decoded status text (resolved history
  is evicted first, then the oldest results), 256 resolved items kept for
  stale links, and 16 subscribers. A subscriber can have at most 64
  unacknowledged updates; if it falls further behind, it gets a single
  `resync` update instead.
- The native window's toolbar shows the Needs-you count. Its popover lists
  requests, failures and results as sanitized plain text. **Open in Pane**
  reveals the pane, and opening a workspace controlled elsewhere asks before
  taking over. **Mark Reviewed** dismisses failures and results. OSC 7501
  reports status only: Swiftty never answers a request for the program.

## Roaming SSH (RST/1)

[spec.roaming.md](spec.roaming.md) (with its Swiftty integration in Appendix A) defines SSH clients for Apple
platforms whose shells survive network changes: a per-user `swifttyd` agent on
the Mac owns the PTY and the authoritative Swiftty terminal, and clients
receive complete current screens over QUIC instead of a byte log. There is no
speculative echo; typing latency is ordinary remote echo.
Appendix B of the spec records the design sources.

| Target | Role |
|---|---|
| `SessionCore` | IDs, limits, input ledger (client queue, host admission), lifecycle, backoff, transfer manifests |
| `ScreenProtocol` | RST/1 messages, framing, RFC 1950 snapshots, validation, snapshot scheduler, bootstrap envelope, `RSTConnection` |
| `SSHClient` | SwiftNIO SSH: host trust, password/Ed25519, exec, shell, SFTP v3 subset, resumable verified transfers |
| `AppleTransport` | Network framework QUIC (ALPN `rst/1`, TLS 1.3, no 0-RTT), exact-certificate pinning, host identity |
| `TerminalHost` | macOS host: exporter, tracked PTY writer, session registry, attachment protocol, control socket |
| `TerminalSurface` | Client: `RoamingClient`, frontend backends (roaming, ordinary SSH, local PTY), SSH and QUIC bridges |
| `CompanionModel` | Bounded watch/iPhone status DTOs; no Swiftty, SSH or QUIC |
| `RoamingApp` (`Apps/Shared`) | Shared app model and SwiftUI for the direct clients |
| `swifttyd` (`Apps/swifttyd`) | `serve`, `bootstrap --stdio`, `install`/`uninstall`/`status` |

Host setup (unified spec §1): there is one PTY owner, the SwiftMux service.
`swiftmux-agent` serves remote clients from the same process as the native
app when a roaming configuration exists at
`~/Library/Application Support/SwiftMux/roaming/config.json` (or
`--roaming-config PATH`, or `$SWIFTMUX_ROAMING_CONFIG`) with an explicit
`bindAddress`, `advertisedHost` and UDP `port` (51222 by default). Enable
Remote Login and install the signed bootstrap helper at
`/usr/local/libexec/swifttyd`; it only relays `bootstrap --stdio` to the
service's control socket (`swifttyd status` checks it). RST/1 session IDs
are SwiftMux workspace IDs, the grant's server instance is the service
epoch, and each attachment takes the workspace's interactive lease: a
workspace the Mac app controls is refused (`writerBusy`) unless the client
resumes with `takeover`. Grant expiry never ends a shell the remote client
did not create. Firewall changes are not made automatically.

Clients bootstrap with `ssh <mac> /usr/local/libexec/swifttyd bootstrap --stdio`
(a no-PTY exec with a length-prefixed JSON request), receive a session grant
with the agent's certificate and a bearer token, and attach over QUIC pinned to
that exact certificate. The apps are generated with XcodeGen:

```sh
Scripts/build-platforms.sh   # iOS, macOS, Catalyst, visionOS, tvOS, watchOS, swifttyd
mise exec -- swift test --filter "ProtocolTests|IntegrationTests"
```

`IntegrationTests/EndToEnd` runs the real registry, PTY, QUIC listener, pinned
client and a presentation-mode display, with and without an in-process SSH
server. Simulator runtimes:

```sh
Scripts/test-roaming-simulator.sh <ios-or-ipad-udid> [iOS|tvOS|visionOS]  # client in the simulator vs a real `swifttyd serve`
Scripts/test-companion-watch.sh <watch-udid>                             # companion tests hosted by the watch app
Scripts/test-real-ssh.sh                                                 # real OpenSSH (apple/container Linux VM) + real swifttyd
```

`test-real-ssh.sh` needs `container`. `swifttyd` is macOS-only, so the Linux
VM's `/usr/local/libexec/swifttyd` relays `bootstrap --stdio` to an agent on
this Mac. macOS Local Network privacy can deny test runners a route to the VM
subnet, so the script reaches sshd through `container exec`.

Roaming verification record (2026-10-10, Xcode 27.0, OS 27 SDKs):

| Destination | Evidence |
|---|---|
| iPhone 16, iOS 27.0.1 (physical) | App UI flow over LAN to real `swifttyd` + OpenSSH; signed Keychain; A2: 50 Wi-Fi↔5G switches over Tailscale, one retained shell, no duplicated input (`Tests/DeviceHandover/Evidence`) |
| iPad Pro 12.9" (5th gen), iPadOS 27.0.1 (physical) | App UI flow over LAN; signed Keychain |
| macOS 27 native, Mac Catalyst | App UI flow; signed Keychain (Apple Development) |
| iOS, iPadOS, tvOS, visionOS simulators | Roaming runtime test vs real `swifttyd`; Keychain |
| watchOS simulator | Companion tests hosted by the watch app |
| macOS host | Unit, integration, end-to-end QUIC and real OpenSSH suites |

QUIC connection migration: clients enable it (`multipathServiceType =
.handover`), but Network framework's QUIC listener on the OS 27 SDK keeps
replying to a client's old address, so a path change ends in reattachment to
the retained session instead (spec §9 fallback). `MigrationTests` documents
the listener behaviour and `RoamingEndToEndTests` checks recovery to the same
shell with each command applied once.

Still open (spec §2.4, §13): physical Apple TV, Vision Pro and paired Apple
Watch runs.

`Scripts/test-handover.sh <iphone-udid> [switches]` runs A2: a standalone app
on the phone keeps one roaming session open while you toggle Wi-Fi, and the
retained shell on the Mac logs one line per switch.

## API and storage contracts

The session, snapshot, input, configuration, and frontend APIs are the embedding
surface. This pre-1.0 package provides source compatibility within patch releases;
minor releases may change public APIs. Internal and `package` declarations have
no compatibility guarantee. Physical row ids, pointer access, storage pools, and
benchmark hooks are implementation details.

`Grid.cells(row:)`, `Grid.historyCells(at:)`, `TerminalState.viewportCells(row:)`,
and `TerminalState.scrollbackCells(at:)` return borrowed spans. End each borrow
before mutating its owner. Grid writes require exclusive access;
`withMutableCells(row:_:)` updates the row extent even when its closure throws.
Indices and allocation sizes are checked before accessing memory. Nonpositive
screen dimensions are clamped to one.

Snapshot spans borrow the snapshot. Retaining a snapshot preserves its cells
while later frames reuse other pool entries. Grapheme ids belong to the snapshot
that produced the cell; passing a cell from another snapshot to
`graphemeScalars(_:)` is invalid even when the numeric id happens to match.

`SWIFTTY_INTERNAL_CHECKS` validates row ownership, ring bounds, blank extents,
grapheme references, and wide-cell structure at completed parser batches and
storage bounds after mutations. Checks and their scratch storage are absent
from normal builds.
`mise run test-internal` enables them. Storage benchmarks vary size and ring layout,
exclude setup from timing, and report consumed results alongside nanoseconds per
operation; run them in Release without internal checks.

Swift formatting follows the pinned Swift Collections configuration: two-space
indentation, 80-column wrapping, and unindented conditional-compilation bodies.
`mise run format-check` also validates documentation comments. Generated Unicode
tables retain their generator's layout. CI requires a self-hosted Apple Silicon
runner labeled `swiftty`, with Swift 6.4, Xcode 27, all supported platform SDKs,
Python 3, and the test tools from `mise.toml` on `PATH`.

## Configuration

Ghostty-style `key = value` files support whole-line `#` comments, repeatable
keys, empty-value resets and `config-file` includes. Unknown keys are reported
and ignored. macOS reads `$XDG_CONFIG_HOME/swiftty/config` (default
`~/.config/swiftty/config`); Settings opens it and Shift-Cmd-, reloads it.
iOS reads `Documents/config`.

```text
font-family = JetBrains Mono
font-size = 14
font-feature = calt
font-variation = wght=500
font-synthetic-style = no-bold
adjust-cell-height = 10%
theme = light:Swiftty Light,dark:Swiftty Dark
background = #1e1e2e
palette = 1=#f38ba8
background-opacity = 0.9
background-blur = true
minimum-contrast = 3
cursor-style = bar
cursor-style-blink = false
cursor-click-to-move = true
copy-on-select = true
link-url = true
mouse-hide-while-typing = true
window-padding-x = 6
scrollback-limit = 20000000
command = /opt/homebrew/bin/fish
keybind = super+shift+k=clear_screen
keybind = ctrl+shift+arrow_up=jump_to_prompt:-1
```

Style-specific font families use `-bold`, `-italic` and `-bold-italic` suffixes.
Cell adjustments accept points or percentages. Foreground, cursor and selection
colors can be configured separately. Themes are searched in
`~/.config/swiftty/themes`, `~/.config/ghostty/themes`, then the built-in
`Swiftty Dark` and `Swiftty Light` themes.

Includes load in declaration order and override earlier settings; nested includes
join the end of the queue. Each file loads once. `config-file =` clears pending
includes. Relative paths resolve against the declaring file; `?path` permits a
missing include, while `"?path"` names a literal leading question mark.
`palette =` clears indexed overrides and restores theme colors.

`command` uses shell expansion, including quotes, variables and globs; `shell:`
selects it explicitly. `direct:` splits arguments on spaces without expansion
or quote processing. Programmatic `SessionConfiguration(command: [...])` passes
arguments directly. `working-directory` accepts a path, `home` or `inherit`.
Desktop launches default to the account shell and home directory; command-line
launches inherit the directory and prefer a nonempty `SHELL`.

Keybinding actions include clipboard operations, font sizing, selection, scrolling,
prompt jumps, search, clear/reset, `text:…`, `csi:…`, `esc:…`, `ignore` and `unbind`;
their names and parameters are defined in
[Keybindings.swift](Sources/SwifttyCore/Config/Keybindings.swift).

Custom shaders use Metal and define
`float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u)`.
See [PostProcess.swift](Sources/SwifttyCore/Renderer/PostProcess.swift) for uniforms.
`position` uses pixel coordinates; normalize it for a `coord::normalized` sampler.
Shaders accessing `u.time` animate continuously. Memory aliases and preprocessor
directives enable animation conservatively; other shaders draw on demand.
Relative shader paths resolve against the declaring configuration file.

## Generated Unicode data

```sh
mise run unicode [EastAsianWidth.txt]
mise run graphemes <ucd-dir>
```

The width generator needs matching `PropList.txt`,
`extracted/DerivedGeneralCategory.txt` and `emoji/emoji-data.txt`; without a path,
it downloads companion files from the same release. Grapheme data must match the
Ghostty comparison build. Both commands stage replacements and reject truncated
inputs missing their final `# EOF` or `#EOF` marker.

## Measured results

These are Release measurements on Apple Silicon. Parser throughput, physical iPad
frame time and the centered onscreen comparison were measured on 2026-10-10.
Earlier probes are identified below.

### Swiftty vs Ghostty

Parser and terminal-state throughput on an Apple M5 Max (18 CPU cores): Ghostty
`5dc28bb`, Zig 0.16.0 ReleaseFast, versus Swift 6.4 Release. Each binary read the
same generated 100 MiB files in 64 KiB chunks at 120×80 with 10,000 bytes of
history. Medians include startup and file I/O: two warmups and 20 serial,
alternating measured runs per binary. Swiftty was faster on all 14 inputs by median.

Lower times are better. Relative throughput is `Ghostty time / Swiftty time`;
100% means equal speed. This benchmark measures parsing and state updates;
the onscreen comparison below measures a separate frontend endpoint.

| Input                |   Ghostty |   Swiftty | Relative throughput |
| -------------------- | --------: | --------: | ------------------: |
| ascii                |   99.0 ms |   93.8 ms |              105.6% |
| cat-source           |  122.0 ms |  114.4 ms |              106.6% |
| compiler-log         |  140.9 ms |  125.1 ms |              112.7% |
| csi-heavy            |  477.5 ms |  357.4 ms |              133.6% |
| ghostty-ascii        |   68.6 ms |   61.0 ms |              112.5% |
| ghostty-osc          | 4104.0 ms | 1092.8 ms |              375.6% |
| ghostty-styled       |  409.1 ms |  211.9 ms |              193.1% |
| ghostty-utf8         |  687.9 ms |  536.7 ms |              128.2% |
| osc-heavy            | 1111.7 ms |  541.4 ms |              205.3% |
| scroll               |  406.4 ms |  303.9 ms |              133.7% |
| unicode-joins        |  348.2 ms |  258.6 ms |              134.7% |
| utf8 (mixed scripts) |  333.1 ms |  332.3 ms |              100.2% |
| utf8-latin           |  129.2 ms |  122.5 ms |              105.4% |
| utf8-cjk             |  100.6 ms |   92.4 ms |              108.9% |

Wide-cell batching cut CJK time by 17.7% versus the frozen previous build. CJK
throughput relative to Ghostty has a 95% paired bootstrap interval of 108.1–110.0%.
Other inputs changed by −1.0% to +1.9% in time. Larger eight-scalar UTF-8 decode
batches were slower and were discarded. Mixed UTF-8 has little margin over Ghostty.
The corpus combines nine Swiftty inputs, four Ghostty inputs (styled: seed 42,
style rate 0.3; UTF-8: seed 42) and a combining/ZWJ/flag fixture.

To compare the same workloads, build Ghostty's benchmark and use generated `.bin`
inputs (`swiftty-bench gen <name>` or `ghostty-gen +<name>`):

```sh
# In the Ghostty checkout:
zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
# In this repository (also builds swiftty-bench in Release):
RUNS=20 mise run compare <ghostty-src> <corpus-dir>
```

### Memory and rendering

Against milestone 1 (`67c8dfa`), the current Release build passed all 18
text-only RSS cases: nine inputs at 120×80 with 10,000-byte and 10 MiB
histories, two warmup pairs and six alternating measured pairs. Median RSS
changes ranged from −30.7% to +0.74%.
Offscreen scrolling at 120×40, 20 lines/frame, improved p95 from 0.640 to
0.508 ms across 20 measured pairs after four warmups (paired change −0.129 ms,
95% interval −0.171 to −0.119 ms). Both builds used Swift 6.4; the display was
locked during this offscreen comparison.

Borrowed grapheme-cache lookups reduced warmed full-redraw allocations to 11
per frame, matching plain text. Median offscreen frame time fell by 17.7% for
combining marks, 12.8% for ZWJ emoji and 10.0% for long clusters.
Parser/grid allocation tests require zero steady-state allocations for common
ASCII, UTF-8, CSI and cell updates. OSC metadata and table growth can allocate.

A physical iPad Pro (12.9-inch, 5th generation), iPadOS 27.0.1, measured the
current core's 120×40 offscreen full redraw at p50 1.580 ms and p95 2.930 ms
(20 warmups, 220 frames). Dense search highlights measured p95 3.030 ms
(five warmups, 35 frames). GPU completion was awaited; both tests passed.

### Onscreen probes

The current Swiftty AppKit view in a Release probe was compared with Ghostty
1.3.1 (15212) on the same M5 Max display. Both used Menlo 13, an 80×24 PTY,
blinking disabled and the same raw-PTY response script.

Three serial alternating pairs posted synthetic keys to trigger alternating
black/white backgrounds. The same independent ScreenCaptureKit observer detected
these changes through a 32×32 crop at the display center, requesting 120 capture
frames/s. Each run used 20 warmups and 100 measured responses; all 720 were
observed. Ranges span runs; lower times are better.

| Terminal      |              p50 |              p95 |
| ------------- | ---------------: | ---------------: |
| Swiftty       | 16.683–16.983 ms | 23.461–24.919 ms |
| Ghostty 1.3.1 | 18.574–21.319 ms | 24.665–25.661 ms |

Median paired p95 difference was −0.742 ms (Swiftty minus Ghostty). This
measures synthetic key-to-captured-pixel delivery, including capture overhead.
Physical-keyboard, glyph-typing and photon-level latency have not been measured.

AppKit now uses two drawables. Matched foreground scrolling probes without
Instruments used 900 updates at 60 Hz and 1,800 at 120 Hz per queue. Compared
with the default three drawables, 120 Hz draw-to-presentation p95 fell from
40.7 to 32.3 ms; presentation-interval p95 stayed at 8.33 ms, with two-refresh
intervals falling from eight to two. Neither run had presentation gaps over
100 ms; earlier multi-second profiled stalls did not recur.

Earlier physical iPad probes at 169×57 presented all 220 measured updates from
a confirmed 120 Hz source after 20 warmups: presentation-interval p95 8.338 ms,
synthetic output-to-presentation p95 24.748–24.797 ms. A 60 Hz probe measured
latency p95 25.961 ms and presentation-interval p95 25.014 ms. All timestamps
were positive. With blinking disabled, the probes observed zero draws during
eight idle seconds and two background seconds with incoming output.

## Verification status

The full macOS Debug/Release baseline passed 1,156 tests. Added keypad-mode coverage
and 86 AppKit checks pass in both configurations. The hosted simulator
passed 171 mobile tests. The current physical iPad build passed 169 correctness
tests and two separate frame-time tests. Release builds passed for visionOS and
Mac Catalyst.

Coverage includes Unicode batching, recorded sessions, shader classification,
visibility/opacity recovery, animation suspension, momentum cancellation and
accessibility. Native probes verified
drawable recovery and draw suspension/restoration on both platforms.
UI automation passed shell typing and Find navigation, highlighting, query/terminal
focus and accessory-bar restoration, including narrow windows and resizing.

Physical keyboard, Find, VoiceOver, link navigation and browser-return redraw
checks passed on both devices; macOS also passed interactive `vim`/`less`, resizing
and scrolling. User checks passed blur and corrected static/animated shaders on
both devices. Scripted and hands-on USB shell checks with `vim`, `less`, `tmux`
and `top` passed on the physical iPad. The user reported typing and scrolling
equally responsive alongside Ghostty in the two-drawable Mac build.
Battery consumption has not been measured.
[todo.tests.md](todo.tests.md) records completed behavior checks and deferred
checks requiring additional protocols or APIs.
