# SwiftMux native workspace UI — screenshot-driven addendum

**Status:** Proposed architecture, not implemented. **Target:** Swift 6.4+, macOS 27, Swiftty-only terminal engine and native AppKit/Metal frontend. **Companion:** `macos-swift-6.4-terminal-multiplexer-spec.md` v0.2.

## Goal

Support the uploaded reference composition: a window-level tab strip with icons and titles; one workspace containing two vertically stacked terminal panes on the left and one tall terminal pane on the right; distinct terminal programs running simultaneously (AI assistant, Git TUI, and interactive game). Preserve shell/process continuity when tabs are switched, panes are rearranged, or the frontend quits.

**Do not implement the UI as a terminal-character compositor.** AppKit owns window chrome, tab strip, split handles, pane headers, focus, and geometry. Swiftty/Metal renders the actual terminal cell grids. SwiftMux service owns sessions, pane identities, PTYs, terminal parsers, history, and canonical layout state.

## 1. Layout model

Represent a workspace as a typed tree, not absolute pixel coordinates:

```swift
indirect enum LayoutNode: Sendable, Codable {
    case pane(PaneID)
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)
}

enum SplitAxis: String, Sendable, Codable { case horizontal, vertical }
```

Define `horizontal` as left/right children and `vertical` as top/bottom children. For the reference:

```text
Workspace "rex-snake"
└── horizontal split (left ~54%, right ~46%)
    ├── vertical split (top ~47%, bottom ~53%)
    │   ├── Pane A: assistant
    │   └── Pane B: Git TUI
    └── Pane C: Snake
```

Ratios are illustrative and must be derived from available window geometry. Each node has a stable identity; each pane is associated with exactly one PTY and one authoritative terminal emulator. Tab and pane titles may be explicit user labels or bounded, sanitized application-reported titles. Tab icons are local UI metadata, not arbitrary remote content.

Native workspace tabs are collections of layouts, not equivalent to pane PTYs. Switching tabs hides views without suspending the server-side processes or parsers. Closing a pane/tab must distinguish `hide`, `detach`, and destructive `terminate`; confirmation is required for destructive actions when the pane is running.

## 2. Server versus native frontend

| Server owns | Native Swiftty app owns |
|---|---|
| Workspace/tab/pane IDs, logical split tree, pane lifecycle | Window/tab strip, focus, pane header, dividers, hover and selection |
| PTY master, child process, exit status, terminal state and bounded history | `MTKView`/MetalRenderer per visible pane, fonts, glyph atlases and GPU resources |
| Canonical pane grid sizes and accepted resize generations | Pixel rectangles and proposed grid sizes computed from fonts, scale and padding |
| Input sequencing, terminal-mode-aware encoding, terminal query replies | AppKit key events, IME composition, paste and native shortcuts |
| Bounded owned frame export and pane events | Frame validation/import, display coalescing and presentation baseline |

Use a single application-level IPC connection and attachment lease per active workspace. Each pane presenter subscribes to its pane via that connection; destroying a view does not close the workspace lease or PTY. On reconnect, request the workspace tree and a complete frame for each visible pane.

## 3. Pane presenter and frame bridge

Swiftty's inspected `TerminalView` owns a concrete `TerminalSession`, while `MetalRenderer.draw` consumes a `RenderSnapshot`. A native SwiftMux pane needs a `MuxPanePresenter` that owns a **client-side frame store**, not another shell/PTY or another parser.

Implement a small, reviewed extension to SwifttyCore that imports **owned semantic frames** into its snapshot storage. Never transmit raw `RenderSnapshot` pointers, spans, pooled storage, `Cell` ABI dumps, GPU buffers, or Swift object serialization. The server exports text/graphemes, cell widths and continuations, attributes/palette, wrap flags, cursor, active screen and dimensions in a versioned bounded IPC schema. Validate counts and sizes before allocation. Initially import all rows as dirty.

Presentation pipeline:

1. Service parses every PTY byte in order into the authoritative pane emulator, including hidden panes.
2. Service publishes an owned full pane frame (later: patches) with pane ID, session epoch, frame revision and geometry revision.
3. App verifies the frame belongs to the current attachment and accepted geometry.
4. Presenter retains at most the current displayed frame, one frame being prepared/drawn, and the newest pending replacement; it never queues unbounded historical repaints.
5. On the main actor, import to owned snapshot storage, schedule the `MTKView`, and draw with Swiftty's Metal renderer.
6. Only after the frame has actually been accepted for presentation may it replace the interaction baseline for hit testing, IME cursor placement, selection and accessibility. A skipped drawable does not advance that baseline.

Do not generate ANSI from remote frames and feed it to `TerminalSession.receive`. That would duplicate parsing and risk divergence from server-authoritative modes. Retain GPU resources until command-buffer completion and CPU snapshots as long as local interaction uses them.

## 4. Native chrome and interactions

- **Top tab strip:** workspace tabs with editable labels, optional local icons, activity/unread indicators, new-tab action, and close/detach behavior. Tab state is a view of server workspace state.
- **Pane headers:** optional program/title label, active-pane indicator, split/zoom/close actions, and bounded activity markers. Sanitize title/control-string text before displaying it in UI.
- **Splitters:** AppKit split views with adjustable ratios, minimum pane dimensions, keyboard-accessible handles and a layout revision. Dragging dividers updates the proposed layout locally; send coalesced resize transactions rather than one RPC per pixel.
- **Focus:** clicking a pane selects its stable ID and routes semantic input to it. Window/tab focus changes are not process termination events.
- **Keyboard:** native shortcuts for new workspace, split, next tab, focus pane, zoom, detach and search; Ctrl-C, arrows, paste and IME commits target the focused pane. App shortcuts must not accidentally be forwarded as terminal input.
- **Selection/search:** initial implementation freezes the displayed viewport for selection/copy. Server provides bounded history/search pages; no live mutation of the copied text. Multi-page selection deferred.
- **Accessibility:** pane names, status, splitter handles, tab titles and displayed text are exposed through AppKit accessibility; do not read mutable server terminal state synchronously on the main actor.

## 5. Resize and full-screen applications

For each pane, the frontend computes columns/rows from the actual Metal font metrics, backing scale and content rectangle, excluding header, padding and split handle. It submits one batch of pane sizes tagged with a layout revision and client geometry generation. The service atomically accepts a valid batch, resizes the terminal emulators and PTYs, then publishes frames with matching geometry metadata. Reject or ignore stale frame/resize generations.

For the Snake game and TUIs such as Git interfaces, preserve alternate-screen mode, raw key input, cursor visibility, terminal queries, bracketed paste and resize notifications. Hidden panes still parse output. A hidden pane retains its last accepted PTY size; remeasure it when made visible. If a pane becomes too small for its program, keep the PTY size valid and show clipping/size guidance rather than inventing a zero-sized terminal.

## 6. Persistence and process lifetime

Keep one unprivileged per-user SwiftMux LaunchAgent owning the PTYs. A native Swiftty window, tab, pane presenter or application process must never own the last reference to a server-side shell. Closing a view detaches its subscription; quitting the app detaches its workspace attachment; only explicit `TerminatePane`/`TerminateWorkspace` commands kill shells. Reopening Swiftty discovers workspaces and requests fresh full frames.

A service crash, user logout or reboot is **not** transparent session restoration. Never replay a previously submitted command to recreate a lost process. Protect the IPC endpoint with same-user peer verification, explicit attachment generation and input/resize fencing. Use bounded queues for PTY writes, terminal parsing and frame delivery.

## 7. Delivery plan

| Milestone | Deliverable | Exit criterion |
|---|---|---|
| A. Native single pane | Swiftty `MTKView` displays a service-owned PTY via imported frames | Quit/reopen app; same shell PID and correct current screen |
| B. Layout tree | Native tabs and recursive split tree, persistent pane IDs | Recreate screenshot's left-stack/right-tall composition |
| C. Interactive correctness | Focus routing, AppKit IME, paste, mouse, resize, TUI modes | Run a Git TUI and an interactive game simultaneously; no misrouted keys |
| D. Lifecycle and history | Detach, tab switching, pane exit, copy/search, frame bounds | Hidden output remains current; reconnect doesn't replay input or kill shells |
| E. Polish | Headers, tab metadata, drag handles, accessibility, activity indicators | Real macOS 27 hardware acceptance and measured memory/latency bounds |

### Required regression tests

- Spawn three independent PTYs, reproduce the reference split layout, and verify distinct input routing and process IDs.
- Switch tabs and close/reopen the app while the game continues; its current screen must converge after reattach.
- Resize rapidly, zoom a pane, and move the window between displays; stale frames must not restore old dimensions.
- Flood one pane with output while typing in another; UI responsiveness and queue memory stay bounded.
- Paste text containing shortcut characters into one pane; no split, tab switch or prefix command occurs.
- Test IME composition, Unicode grapheme widths, selection of changing progress output and cursor placement.
- Simulate renderer failure/no drawable and client crash; no server PTY termination or premature presentation baseline advancement.
- Verify explicit destructive actions terminate the intended pane only; view disposal never does.

## 8. Relationship to earlier SwiftMux spec

This addendum makes the **native Swiftty application** the preferred final frontend for screenshot-style workspaces. If the `swmux` terminal-within-terminal client has no independent product value, skip its TTY compositor and decoder entirely and deliver the native single-pane milestone first. The service, PTY lifecycle, bounded input, session graph and owned frame protocol remain necessary either way.

It does **not** add SSH, SFTP, QUIC or mobile roaming to the local multiplexer. Those can attach to the same canonical server-owned pane model through separately specified transports later.

## Primary source references

- tmux project: <https://github.com/tmux/tmux>
- Swiftty `TerminalView`: <https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/Swiftty/TerminalView.swift>
- Swiftty `TerminalSession`: <https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/SwifttyCore/Session/TerminalSession.swift>
- Swiftty `RenderSnapshot`: <https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/SwifttyCore/Renderer/RenderSnapshot.swift>
- Swiftty `MetalRenderer`: <https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/SwifttyCore/Renderer/MetalRenderer.swift>

**Verification:** This is a proposed specification based on the reference image and previously inspected source. No build, renderer import implementation, or integration test has been run.
