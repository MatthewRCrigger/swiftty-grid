# Swiftty specification

## Goal and scope

Build a small Swift 6.4 terminal core with libghostty behavioral parity for Apple
frontends. Prioritize native Swift APIs, Apple Silicon performance, borrowed
storage and direct Darwin/CoreText/Metal integration. Measure improvements;
a small C helper is acceptable when justified.

| Platform               | Core       | Local PTY   | Frontend             |
| ---------------------- | ---------- | ----------- | -------------------- |
| macOS                  | required   | required    | AppKit, required     |
| iOS/iPadOS             | required   | unavailable | UIKit, required      |
| Mac Catalyst, visionOS | must build | unavailable | UIKit reuse optional |

Scope includes session lifecycle, parsing, terminal state/history, input encoding,
resize, Unicode/graphemes, snapshots, fonts, rendering and frontend features.
The embedder owns external transports, connections, authentication and window/tab/
split management; the Swiftty app's own SwiftMux workspace window is specified
below. Linux, Windows, GTK, OpenGL, WebAssembly, plugin APIs and a
stable core C ABI are excluded; Shell supplies its own libghostty embedder API.
Sixel is excluded. Kitty graphics is future work; until separately specified,
ignore APC strings safely. Future graphics support should use bounded image
storage and cover transmission, placement, deletion, z-order and placeholders.

Implementation and verification status belong in [README.md](README.md).

## Architecture and ownership

```text
AppKit / UIKit frontend
          ↓
TerminalSession — one serial queue owns parser and terminal state
  ├─ PTYProcess (macOS) or embedder-supplied byte stream
  ├─ Parser → TerminalState (grid, history, modes, graphemes, status)
  ├─ InputEncoder
  └─ immutable RenderSnapshot → MetalRenderer + CoreTextFontManager
```

Keep targets coarse: `SwifttyCore`, `Swiftty`, `SwifttyMobile`. Within the core,
use `Session`, `Process`, `Terminal`, `Input`, `Unicode`, `Font`, `Renderer` and
`Config` directories. Frontends share everything below view hosting. Isolate
platform code with conditional compilation; avoid a portability layer or
internal C-shaped APIs.

`TerminalSession` provides `start(_:)`, `receive(_:)`, `onWrite`,
`resize(columns:rows:)`, `send(_:)`, `snapshot()` and `stop()`.
PTY I/O uses Darwin `openpty`, `termios`, `ioctl`, `posix_spawn`, dispatch-source
reads and descriptor writes; always reap children, including after stop.
External transports deliver output through `receive`, forward encoded input and
replies, and propagate resize.

I/O enters the existing session queue; UI runs on the main actor. Renderer access
stays on the main thread/render callback.
Use immutable snapshots and coarse synchronization; avoid actors or locks in
parser/grid loops and cross-thread terminal-state mutation.

### SwiftPM C security settings

The Xcode app wrappers compile Swift only; their C/Objective-C warnings do not
configure the SwiftPM C targets `SwiftMuxLauncher` and `CAllocCounter`.
Adding warning flags through `cSettings.unsafeFlags` remains deferred: it was
not approved in the recorded security-settings review, and unsafe flags would
prevent use of the affected package products as remote dependencies.
`CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`, `CLANG_WARN_ASSIGN_ENUM`,
`GCC_WARN_SIGN_COMPARE` and `CLANG_ANALYZER_SECURITY_BUFFER_OVERFLOW_EXPERIMENTAL`
would matter through those C targets rather than the Swift app wrappers.

`ENABLE_C_BOUNDS_SAFETY` also remains deferred. It requires an annotation-based
programming model, with `Sources/SwiftMuxLauncher/main.c` the candidate scope;
the recorded adoption workflow is the `adopt-c-bounds-safety` skill. This is a
separate source-adoption task, not an enabled build flag. App-target settings and
platform exceptions live in
[the roaming specification](spec.roaming.md#25-xcode-security-build-settings).

## Memory, parsing and Unicode

- Common parser and cell-update paths must avoid heap allocation, input-to-`String`
  conversion, repeated `Data` copies, unnecessary ARC and uncontrolled copy-on-write.
  Prefer borrowed `Span`, unique non-copyable ownership, small `InlineArray` storage
  and reusable contiguous buffers.
- Store `BitwiseCopyable` cells in contiguous row-major storage: no cell objects,
  row dictionaries or allocation during ordinary mutation. Reuse resize storage
  where practical. Additional cell metadata belongs in side tables keyed by ID.
- Parse borrowed bytes in batches with a non-copyable state machine, SIMD printable
  scanning and inline UTF-8 decoding optimized for Apple Silicon. Safely ignore
  unsupported or malformed sequences according to terminal rules.
- Use scalars, generated width/grapheme tables and explicit cell semantics rather
  than `Character` storage. Preserve wide cells and grapheme behavior through
  wrap, scroll and resize/reflow.

## Rendering and fonts

Snapshots contain only renderer data and damage. Rebuild damaged rows, retain GPU
buffers and avoid whole-grid copies per frame. Retain damage across missing
drawables and retry a skipped final presentation. Share one Metal renderer across
platforms, with shaders in `.metal` files.
Draw only when needed; suspend frame driving and blink timers for detached,
hidden, fully transparent or empty views and occluded macOS windows. Retain pending
output through fades and opacity pulses; draw while visible and resume animation
on restoration. UIKit also stops momentum while invisible and suspends rendering
and momentum in the background.
Blinking and animated post-processing are the only independent animation sources.

Use CoreText for primary/bold/italic/bold-italic faces, fallback fonts, emoji and
OpenType shaping. Support family per style, point size, features, variations,
synthetic-style controls and cell-size adjustments; default iOS sizing follows
Dynamic Type. Draw box/block/Braille/sextant/Powerline glyphs procedurally.
Render underline styles/colors, blinking text, minimum contrast, opacity/blur and
custom Metal post-processing shaders.

## Frontend milestones

| Milestone     | Required behavior                                                                                                                                                                                                                                                                                      |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1: macOS      | Shell PTY, typing/IME, colors, cursor, reflow, history, alternate screen, mouse, selection/copy, search, clipboard, common prompts and TUIs                                                                                                                                                            |
| 2: iOS/iPadOS | Metal `UIView`, `UITextInput` for keyboard/dictation/IME, hardware key press/release, Esc/Ctrl/Alt/Tab/arrows/symbol accessory bar, touch selection/handles/edit menu, momentum scrolling, touch/pointer mouse reporting, multitasking resize/keyboard avoidance, lifecycle pausing, local demo source |
| 3: protocols  | Semantic prompt marks/jumps/output selection/redraw/click-to-move, underline colors/styles, blinking text, title/SGR stacks, pointer shapes, color-scheme and resize reports, alternate-key encoding and hyperlinks                                                                                    |
| 4: embedding  | Ghostty-style supported configuration/themes, keybinding actions, font/render options, find controls and VoiceOver on both frontends                                                                                                                                                                   |

Milestones require behavioral tests and the performance gates below. Network
clients and frontend window management remain embedder responsibilities.

### Terminal protocols

| Family               | Required support                                                                                                                                                                                         |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C0                   | BEL, BS, HT, LF, VT, FF, CR, SO, SI, CAN, SUB                                                                                                                                                            |
| ESC                  | DECSC/DECRC, IND, NEL, HTS, RI, RIS, DECKPAM/DECKPNM, G0/G1 designation including DEC Special Graphics, DECALN                                                                                           |
| CSI movement/editing | CUU/CUD/CUF/CUB/CNL/CPL/CHA/CUP/HVP/VPA/VPR/HPA/HPR/CHT/CBT; ED/EL/ECH/ICH/DCH/IL/DL/SU/SD/REP                                                                                                           |
| CSI state            | TBC, DECSTBM, DECSLRM, SGR (16/256/truecolor, colon subparameters, underline styles and SGR 58/59), SCOSC/SCORC, SM/RM, DECSET/DECRST/DECRQM, DECSCUSR, DECSTR                                           |
| Reports/stacks       | DSR 5/6, DA1/DA2, XTVERSION, XTWINOPS 14/16/18/22/23, XTPUSHSGR/XTPOPSGR (`# {`, `# }`, `# p`, `# q`), color scheme (`? 996 n`)                                                                          |
| Modes                | DEC 1, 3 (with 40), 5, 6, 7, 9, 12, 25, 45, 47, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1045, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 2048; ANSI 4, 20                                           |
| Input                | Kitty keyboard query/push/pop/set and flags 1/2/4/8/16; X10/normal/any-motion, legacy/UTF-8/SGR mouse; bracketed paste and focus reports                                                                 |
| OSC                  | 0/2 title, 7 cwd, 8 links, 52 clipboard writes, 133 prompts, 21 colors, 22 pointer, 4/10/11/12 set/query and 104/110/111/112 reset, 9 and `777;notify` notifications, `9;4` progress, opt-in 7501 status |
| DCS                  | Streamed tmux control mode (`1000 p`), XTGETTCAP (`+ q`), DECRQSS (`$ q`)                                                                                                                                |

Unknown sequences and other DCS/APC/PM/SOS strings must be ignored safely.
OSC 52 accepts padded/unpadded Base64 and an empty clipboard clear; invalid
characters, whitespace or malformed explicit padding reject the entire write.
Clipboard reads are refused. Paste replaces editing, signal and escape controls
with spaces. Unbracketed LF/CRLF becomes one CR; bracketed paste preserves line
endings and frames empty input. Unsupported upstream protocols/API cases are
tracked in [the deferred terminal checks](todo.md#deferred-terminal-feature-checks).

Committed typing/IME text without a physical key uses key code zero when Kitty
flag 8 is set; flag 16 adds its Unicode scalars as associated text. Other flags
retain UTF-8 commits. Key-report mode refuses committed text containing C0, DEL
or C1 controls; control actions use key events and explicit byte writes stay raw.
PTY and SSH admission reserve the largest possible encoding before queueing,
because keyboard modes can change before encoding. This may refuse a large
commit even when its current UTF-8 encoding would fit the pending-byte limit.

## OSC 7501 program status

The core owns protocol validation, state, lifecycle and support replies.
Embedders own badges, notifications, acknowledgment, permission UX, aggregation
and pane-specific transport routing. Keep status distinct from OSC 9;4 progress;
never persist it into a newly created process or interpret it as approval.

### Framing and fields

```text
ESC ] 7501 ; ? ST
ESC ] 7501 ; key=value:key=value... ST
```

Accept BEL or ST across arbitrary input chunk boundaries. Use a dedicated
bounded capture path and apply only complete, validated commands. An over-limit
report must be discarded in full, without applying a truncated prefix.

| Limit                                        |                       Bytes/count |
| -------------------------------------------- | --------------------------------: |
| Whole sequence, including framing/terminator |                        4096 bytes |
| Key                                          |                          16 bytes |
| ID / segment / depth                         | 128 bytes / 32 bytes / 8 segments |
| `app`                                        |                          32 bytes |
| `title`, encoded / decoded                   |                   256 / 192 bytes |
| `msg`, encoded / decoded                     |                 2732 / 2048 bytes |

- `state` is required and case-sensitive: `idle`, `working`, `done`, `blocked`,
  `error` or `clear`. Missing/unknown state rejects the report; `clear` is a
  mutation, never a retained state.
- Omitted `id` addresses the root (`""` in the API). Non-root IDs are slash-separated
  nonempty `[A-Za-z0-9_.+-]` segments. Invalid IDs reject the whole report,
  including clears; they must never fall back to root.
- Trim surrounding whitespace on keys and values before field validation;
  a spaced `id` must retain its scope rather than become an omitted ID.
- `progress` is decimal 0–100 for `working`/`blocked`; invalid values are absent.
  `kind` applies only to `blocked`: `permission`, `question` or `auth`;
  unknown values are absent. `app` uses the segment character set.
- `title`/`msg` are standard-alphabet Base64, padded or unpadded, decoding to
  bounded valid UTF-8. Empty values are absent. Reject invalid decoded text,
  C0/DEL/C1 controls and field-limit violations before any mutation.
- Keys use lowercase ASCII letters; value bytes use `[A-Za-z0-9_.,+/=-]`.
  Unknown keys and individually malformed pairs may be ignored; applicable
  repeated keys use the last value, subject to whole-report validation.

Decoded text remains untrusted. Never execute it or interpret it as markup.
Other format characters survive decoding; trusted UI must strip or isolate
bidirectional controls (U+200E/F, U+202A–202E, U+2066–2069).

### Store and lifecycle

The authoritative `ProgramStatusStore` lives in `TerminalState`, independent of
rendering-surface lifetime. Apply commands and lifecycle operations in session
stream order. Keep one record per ID, including root, ordered least recently
updated first. Reports replace the whole record: omitted fields disappear.
A child does not require a stored parent; `app(for:)` resolves its nearest
ancestor's app, then root.

Root clear removes all records. Child clear removes its exact ID and descendants
whose prefix is followed by `/`: clearing `build` removes `build/test`, never
`builder` or `other/build`. Bound storage at 256 records and evict the least
recently updated on insertion; updating an ID moves it to newest.
Observable mutations increment the store revision; invalid/no-op commands do not.
Revisions saturate at `UInt64.max`; consumers must then compare records or use
change notifications.

| Event                                        | Required effect                                                                                                                                                                  |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Genuine new prompt (OSC 133 A or equivalent) | Remove `idle`, `working`, `blocked`; retain `done`/`error`. Continuation/redraw markers are not command boundaries.                                                              |
| RIS/full reset                               | Clear all records before publishing reset completion. Soft reset preserves them.                                                                                                 |
| Process/session exit                         | Remove transient records; retain existing `done`/`error`, never infer either from the exit code. PTY sessions do this automatically; external transports call `programExited()`. |
| Disable consumption                          | Ignore reports/queries, send no support reply and clear retained records.                                                                                                        |
| Capture reconstruction                       | Explicit `resetForCapture()` preserves records; `continueStream(from:)` restores parser/status state in order. Ordinary RIS still clears status.                                 |

### Consumer and reply contract

`ProgramStatusState` and `ProgramStatusBlockedKind` are typed enums.
`ProgramStatusRecord` exposes immutable `id`, `state`, optional `kind`/`progress`/
`app`/`title`/`message`, and `revision`. `ProgramStatusSnapshot` contains immutable
ordered `records` and `revision`; both are `Sendable` and `Equatable`.

Enable consumption explicitly with `SessionConfiguration.programStatusEnabled`
or `setProgramStatusEnabled(_:)`. Newly attached consumers can immediately read
`TerminalSession.programStatusSnapshot`; `onProgramStatusChange` publishes after
mutation, including status-only updates without cell damage. Copy parser scratch
storage before publication. UI dispatch belongs to the embedder. Presentation
notifications may coalesce, but mutations must not be skipped or reordered.

An enabled support query receives `OSC 7501 ; ?` with its matching BEL/ST
terminator; ordinary reports generate no reply. Deliver generated bytes through
`onTerminalReply: (@Sendable ([UInt8]) -> Void)?`, distinguishable from keyboard/
paste input. Without that callback, transport delivery falls back to `onWrite`;
a PTY sends replies directly to its child. Embedders requiring provenance must
install the callback and route replies to the originating terminal/pane, including
tmux control-mode topologies. Replies and snapshots must work without a surface.

### Required coverage

Cover states/kinds/fields, Unicode, all split boundaries, multiple sequences,
repeated/unknown/malformed pairs, invalid/missing state, ID grammar/depth/length,
each limit boundary including whole sequence ±1, progress edges, Base64/UTF-8/
control rejection and disabled consumption. Verify replacement, root/child clear,
prefix collisions, ordering, capacity/eviction and revisions. Exercise prompt/
reset/exit/reconstruction in stream order, surface-independent publication and
BEL/ST reply provenance. Existing OSC 9;4, OSC 133, reset and response tests
must continue passing. The embedder must consume status without parsing OSC itself.

## SwiftMux native workspace

The Swiftty app is also the native frontend for SwiftMux, the persistent
per-user session service. The service, its wire protocol and its acceptance
record are in [spec.multiplexer.md](spec.multiplexer.md). Remote attachment,
leases, the attention inbox and deep links are in
[spec.inbox.md](spec.inbox.md). This section covers the native workspace
window.

**Not a character compositor.** AppKit draws the window chrome: tab strip,
dividers, pane headers, focus and geometry. Swiftty's Metal renderer draws
each pane's cells. The service owns sessions, pane identities, PTYs, parsers,
history and the canonical layout. The `swmux` terminal client remains a
secondary frontend.

**One window type.** Every terminal window the app opens is a workspace
window, and a plain shell is the smallest workspace: one tab, one pane, one
login shell. Adding a tab or splitting grows the same workspace; it never
restarts, transfers or recreates the original process. There is no second,
app-owned terminal window: `TerminalView` and `TerminalSession` remain
reusable library APIs (the roaming clients and tests use them), but a shell
in a workspace is never an app-owned `TerminalView` session. Presentation
helpers are shared where useful, without a second authoritative emulator.

### Commands

**Terms.** *Workspace* names the persistent thing a person creates, opens,
renames and ends; *window* names only its on-screen view. Commands on the
workspace say Workspace (the Workspace menu, New Workspace, End Workspace);
Close Window and the Window menu act on the window and leave the workspace
running. Tabs and panes are parts of a workspace.

The window starts with minimal chrome (workspace title, the terminal, add
and inbox controls) and shows the tab strip once there is a choice. Access
to the workspace chooser and lifecycle commands is never hidden.

| Command | Meaning |
|---|---|
| New Workspace (⌘N) | Create one workspace with one shell, in its own window. |
| New Tab (⌘T) | A shell in a new tab of the focused workspace. |
| Split Right / Split Below | A sibling shell in the current tab's split tree. |
| Open Workspace… (⇧⌘O) | List workspaces; reveal one this app shows, or attach it in another window. Opening never creates a shell; the chooser's New Workspace button does, as ⌘N would. |
| Rename Tab / Workspace | Metadata only. |
| Close Window (⌘W) | Detach this window; processes keep running. |
| End Pane / Tab / Workspace | Terminate exactly that scope, confirming while processes run. A tab's close button says it ends its processes. |

Commands travel the responder chain to the key window's controller and are
validated against that window's actual attachment (connected, controller,
target present). A text field (search, a tab rename) and IME composition
keep their own editing commands. Helper management (staging and installing
updates) sits under the app menu's Terminal Service item.

### Startup and discovery

- **First launch** creates a one-shell workspace.
- **Later launches** reopen the last workspace when it is free, or the only
  free workspace when the last is unknown or gone; otherwise they offer the
  existing workspaces before creating another. The remembered value is an
  identity, never a copy of the split tree.
- **Opening** a workspace this app shows reveals its window. One held by
  another client needs an explicit takeover; declining or failing leaves the
  current windows usable.
- **Service unavailable** (helper missing, awaiting approval, unreachable or
  a different running version): the app says so and offers a retry. It never
  starts a non-persistent local shell instead.

### App coordination

`WorkspaceCoordinator` owns the application-level registry:
- create, open and reveal are distinct operations, and a repeat while one
  is pending joins it;
- windows are keyed by service instance and workspace identity, never by
  name; a window that lost its lease or connection matches nothing, so a
  service-instance change invalidates stale registrations;
- each window has its own connection and holds its workspace's lease;
  reopening a workspace already shown reveals it rather than adding a writer;
- configuration reload, staged-update detachment and Quit apply to every
  window; closing one window never detaches another; attention links reveal
  or open their target without detaching an unrelated window.

The coordinator manages windows, the window controller presents one
attachment, and the service stays authoritative for workspace and process
state; no client-side workspace tree mirrors it.

### Launch settings

`WorkspaceLaunch` turns configuration into a new workspace's `LaunchSpec`
with the rules of `Configuration.sessionConfiguration()`:
- `command` keeps Ghostty's `shell:` expansion and `direct:` arguments;
  unset runs the login shell;
- `working-directory` is an explicit path, `home`, or `inherit`, which
  resolves in the frontend (its current directory) because the agent runs
  elsewhere;
- the frontend's environment is snapshotted; the service still sets the
  terminal variables it requires over it.

New tabs reuse the workspace's spec; splits start a login shell in the split
pane's directory. `scrollback-limit` is not carried: the service applies its
own history limit to every pane.

### Layout model

A workspace holds tabs, and each tab holds a typed split tree. Layouts are
never stored as absolute pixel coordinates.

```swift
indirect enum LayoutNode { case pane(PaneID); case split(axis:ratio:first:second:) }
enum SplitAxis { case leftRight, topBottom }
```

- **Splits:** `leftRight` has left/right children and `topBottom` has
  top/bottom children. `ratio` is the share given to `first`, in (0, 1).
  It is derived from the available geometry and changed by dragging a
  divider.
- **Panes:** each pane has a stable ID, one PTY and one authoritative
  emulator.
- **Titles:** a tab or pane title is either a user label or a bounded,
  sanitized title reported by the program. Tab icons are local UI metadata,
  never remote content.
- **Tabs:** switching tabs hides views without suspending server-side
  processes or parsers.
- **Close actions:** hiding, detaching and terminating are distinct.
  Terminating a running pane or tab asks for confirmation first.

### Ownership

| Service owns | Native app owns |
|---|---|
| Workspace, tab and pane IDs; split tree; pane lifecycle | Window, tab strip, focus, pane headers, dividers, hover, selection |
| PTY, child process, exit status, terminal state, bounded history | One `MTKView` and Metal renderer per visible pane; fonts, atlases, GPU resources |
| Canonical grid sizes and accepted geometry generations | Pixel rectangles and proposed grids from font metrics, scale and padding |
| Input sequencing, mode-aware encoding, terminal query replies | AppKit key events, IME composition, paste, native shortcuts |
| Bounded owned frame export and pane events | Frame validation and import, display coalescing, presentation baseline |

One XPC connection holds the interactive lease for the attached workspace.
Each `MuxPaneView` subscribes to its pane through that connection. Destroying
a view never ends the lease or a PTY. On reconnect the app requests the
workspace tree and a complete frame for every visible pane.

### Pane presenter and frame bridge

`MuxPaneView` keeps a client-side frame store. It never runs another shell,
PTY or parser. The service exports **owned semantic frames** (`PaneFrame`):
- graphemes, cell widths and continuations;
- attributes and palette;
- wrap flags, cursor, active screen and dimensions;
- revision and geometry identity.

The bridge (`SwiftMuxBridge`) validates counts and sizes before allocating,
then imports the frame into snapshot storage for the renderer. It never sends
raw `RenderSnapshot` pointers, pooled storage, cell ABI dumps, GPU buffers or
Swift object serialization. It never turns frames back into ANSI for a second
parser.

The pipeline:
1. **Parse.** The service parses every PTY byte in order, including for
   hidden panes.
2. **Publish.** It publishes a full owned frame tagged with pane, attachment,
   revision, layout revision and geometry generation.
3. **Check.** The app accepts the frame only for the current attachment and
   accepted geometry.
4. **Bound.** Each presenter keeps the displayed frame, one frame in
   preparation and the newest pending replacement, never a backlog.
5. **Draw.** On the main actor it imports the frame, schedules the `MTKView`
   and draws.
6. **Advance the baseline.** Only a frame actually accepted for presentation
   replaces the interaction baseline used for hit testing, IME placement,
   selection and accessibility. A skipped drawable does not advance it. GPU
   resources live until their command buffers complete.

### Interaction

- **Tab strip:** editable labels, local icons, activity dots, new tab, and
  separate close and detach actions. It is a view of the service's workspace
  state.
- **Pane headers:** the program or title label, an active-pane indicator,
  and split, zoom and close actions. Title text is sanitized before display.
- **Dividers:** adjustable ratios with minimum pane sizes, keyboard- and
  VoiceOver-adjustable. A drag updates the proposed layout locally and sends
  coalesced geometry, never one request per pixel.
- **Focus and keys:**
  - Clicking a pane focuses it by ID, and semantic input goes to the focused
    pane.
  - Window and tab focus changes never end processes.
  - App shortcuts (new tab, split, focus, zoom, resize, end pane or tab,
    find) are never forwarded as terminal input.
  - Ctrl-C, arrows, paste and IME commits go to the pane.
- **Selection and search:** selection freezes the displayed viewport for
  copy. Find runs the service's bounded history search. Selection across
  fetched pages is deferred.
- **Accessibility:** pane names, status, dividers, tab titles and displayed
  text are exposed through AppKit accessibility. Mutable server state is
  never read synchronously on the main actor.
- **Attention inbox:** the toolbar badge and popover are specified in
  spec.inbox.md §3.5.

**Terminal parity.** A workspace pane offers what a direct terminal window
did. Behaviour that needs the emulator runs in the service and is advertised
in `Welcome.features` (spec.multiplexer.md §7.5); a frontend disables the
matching menu items with a service that lacks it, rather than leaving them
inert:
- mouse reporting to programs (Shift still selects), button and any-motion
  modes, and the alternate-screen wheel sending arrows;
- `copy-on-select`, `cursor-click-to-move`, `mouse-hide-while-typing` and
  `custom-shader` (animated shaders drive frames);
- ⌘-click and ⌘-hover links (OSC 8, or detected URLs with `link-url`);
- prompt jumps, scroll to top, Select Command Output, Clear Screen and Reset
  Terminal, from menus and key bindings;
- user key bindings, search, font zoom, theme and padding as in the direct
  view.

### Resize and full-screen programs

- **Geometry batch:** for each visible pane the app computes columns and rows
  from the real font metrics, backing scale and content rectangle, excluding
  the header, padding and divider. It submits one batch tagged with the layout
  revision and a client geometry generation. The service accepts a valid
  batch atomically, resizes emulators and PTYs, then publishes frames carrying
  the matching generation. Stale frames and stale batches are ignored.
- **Full-screen programs:** alternate screen, raw keys, cursor visibility,
  terminal queries, bracketed paste and resize notifications behave as in a
  plain Swiftty window.
- **Hidden and small panes:** a hidden pane keeps parsing and keeps its last
  accepted size until it is visible again. A pane too small for its program
  keeps a valid PTY size and clips; it is never zero-sized.

### Lifetime

A window, tab, pane view or app process never owns the last reference to a
shell.
- Closing a view ends its subscription.
- Quitting the app detaches its lease.
- Only an explicit end of a pane, tab or workspace kills shells.
- Reopening the app lists workspaces and requests fresh full frames.

- A shell that exits follows the service's exit and remain-on-exit rules; no
  empty workspace snapshot is invented.
- Another client taking control stops this window's input and shows it
  detached.
- After an agent restart, workspaces are listed and identities resolved
  again; old leases, process IDs and queued input are never reused.

"Persistent" means shells outlive windows and the app while the service runs.
A service crash, logout or reboot is not restored transparently, and no
submitted command is ever replayed to recreate a process. The endpoint checks
that the peer is the same user, and every lease, input and resize is fenced
by attachment generation. Queues for PTY writes, parsing and frame delivery
are bounded.

### Required coverage

- Three independent PTYs in a left-stacked, right-tall layout, with distinct
  input routing and process IDs.
- Switching tabs and quitting and reopening the app while a full-screen
  program runs; its screen converges after reattach.
- Rapid resize, zoom and moving between displays; stale frames never restore
  old dimensions.
- One pane flooding output while typing in another; the UI stays responsive
  and queue memory stays bounded.
- Pasting text that contains shortcut characters never triggers a split, tab
  switch or prefix command.
- IME composition, grapheme widths, selection of changing output and cursor
  placement.
- Renderer failure, missing drawables and a client crash never end a PTY or
  advance the presentation baseline early.
- An explicit destructive action ends only the intended pane; disposing a
  view never does.
- New Workspace makes exactly one workspace, tab and shell; a second makes
  another workspace; New Tab and Split keep the original shell.
- Two windows are controlled independently; commands reach only the focused
  one, and Open Workspace never duplicates a writer or PTY.
- Closing a window during create, open or takeover retires the pending
  operation; a timeout after a possible create does not create again, and
  the workspace stays listed.
- Custom commands and directory policies match the direct-window rules.
- The parity features above, including text-field focus and IME.
- Helper approval, absence, unavailability and a different version are
  recoverable, with no direct-shell fallback.
- Configuration reload and Quit reach every window; stale service instances
  and frames are rejected; attention links detach no unrelated window.

Status and measurements for these are recorded in spec.multiplexer.md §11.

## Performance and acceptance

| Metric                                            | Requirement                             |
| ------------------------------------------------- | --------------------------------------- |
| Common parser-loop / cell-update heap allocations | 0 / 0                                   |
| Typing latency                                    | no measurable regression                |
| Supported-feature correctness tests               | 100% pass                               |
| Scroll performance                                | no regression from milestone 1          |
| Text-only RSS                                     | ≤15% above milestone 1                  |
| Ordinary-use frame pacing                         | no dropped frames at display rate       |
| UIKit energy behavior                             | no rendering while idle or backgrounded |

Parser throughput must reach ≥95% of upstream Ghostty for every comparison input,
or ≥90% for wide-character-heavy inputs (`Scripts/compare-ghostty.sh`). Maintain
100 MB ASCII/UTF-8, compiler-log, source-file, full-redraw, scroll, resize-stress,
OSC-heavy and CSI-heavy benchmarks. Measure throughput, CPU time, allocations,
peak RSS, frame time and p95 input-to-render latency on Apple Silicon Release
builds; also measure frame time on a physical iPad. Prioritize measurable latency,
throughput and iOS battery behavior over generic architecture or Swift purity.

Tests must cover:

- Parser/state golden cases: CSI/OSC/DCS/APC/SGR, malformed input, cursor/erase/modes,
  UTF-8, history, reflow, alternate screens, wide cells, graphemes and semantic prompts.
- Ghostty oracle cases driven through terminal sequences.
- Real macOS PTY sessions (`sh`, `vim`, `less`, `tmux`, `top`) and recorded iOS
  replays through `receive`.
- Frontend key/IME/selection behavior.

Use window-independent tests where possible and hosted tests for UIKit behavior.

Parity is complete only when:

- All milestones pass their tests and performance gates.
- Both apps support daily shell/TUI work, with supported behavior matching Ghostty.
- Hot paths allocate effectively zero.
- macOS input/render latency is indistinguishable from Ghostty.
- The Swift core remains materially smaller and simpler than a mechanical port.

Automated and offscreen results alone do not establish the interactive acceptance
requirements.
