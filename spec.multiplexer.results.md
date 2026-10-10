# SwiftMux: acceptance and measurement record

Branch `feat/swiftmux`, 2026-10-10. Host: Apple silicon MacBook Pro, 18 cores, macOS 27.0.1 (26A434). Toolchain: Swift 6.4 (swift-6.4-RELEASE), Xcode 27 SDK. Only this combination has been built and tested.

## Acceptance gates (spec §10)

| Gate | Evidence |
|---|---|
| C1 Compiler and package | Debug and release builds pass. `Scripts/package-swiftmux.sh` produces a hardened-runtime `Swiftty.app`, signed ad hoc or with **Developer ID Application: Dot Media CC (72KB9YQR7B)**; `codesign --verify --strict` passes for both. `swiftty --swiftmux-agent register` moved the agent from `notFound` to `enabled` through `SMAppService`, and launchd started it on demand. On the Developer ID build the agent derives its peer requirement from its team: the team-signed `swmux` is served, and an unsigned client gets no answer and now fails its handshake after 5 s (`PeerIdentityTests`). After the same label is re-signed with a different identity, launchd refuses the spawn (`EX_CONFIG`, stale launch constraint) until the agent is re-registered. The update flow therefore unregisters before it replaces the bundle. Notarization has not been tested. |
| C2 PTY/job control | `ServiceTests.controllingTerminalAndJobControl`: `tty`, `/dev/tty`, session leadership and Ctrl‑C (exit status 130). |
| C3 Lifetime | Run on both the ad-hoc and the Developer ID packages with the agent registered: the service instance, shell PID and background-job PID were unchanged after the app was Force Quit (SIGKILL), quit normally and crashed (SIGSEGV), and `swmux end` ended only its target. `reattachKeepsSameShell` covers client death and reattachment to the same shell, `TerminalClientTests` covers TTY detach, and the native split/close test covers closing the window. |
| C4 Completion | `naturalExitDrainsFinalOutput` (final output and exit status). `lateSpawnIntoEndedPaneIsReaped`. Forced close is bounded: SIGHUP, then SIGKILL after 2 s, and the forced kill is logged. |
| C5 Terminal behaviour | Engine parity in `BridgeTests` (wide, emoji, combining, SGR and underline colours, wraps). `detachedPanesStillAnswerQueries` (DA reply with no frontend attached). Existing Swiftty engine suites. |
| C6 Geometry and identity | `staleGeometryAndAttachmentAreRejected`, `splitZoomAndEndPane`, `incompatibleVersionIsRejected`, and the native split and divider test. |
| C7 Input and paste | `bracketedPasteAndCancelOnDisconnect`, ordered `enqueue`, and the native IME test (text delivered exactly once). Nothing is replayed automatically. |
| C8 Bounds and fairness | `slowClientStaysBoundedAndResponsive`, `inputBeyondWriterCreditIsRejected`, `paneLimitRejectsExcessCreation`, and the 32-pane load below. |
| C9 Owned frames and history | `BridgeTests` (malformed frames rejected), `historyScrollAndSearch` (a stale address is refused), and the native frozen-selection test. |
| C10 Registration and upgrades | `UpdateTests`: staging changes nothing, cancelling restores admission, a barrier timeout preserves sessions, and the update follows the ordered barrier. A wrong-version client gets an explanation instead of replacing the running service. |

Native resource lifetime: in "slow GPU and missing drawables never advance the presented baseline", all in-flight GPU slots are held, newer frames arrive and the presented frame and accessibility text stay unchanged until capacity returns. Content is also never presented while the view is out of its window (an offscreen `MTKView` still hands out drawables, so the pane view now treats that case as no drawable).

Frontend gates: the decoder, diff renderer and full client are exercised against a fake outer terminal parsed by the Swiftty engine (`TerminalFrontendTests`). Native rendering, IME, selection, accessibility, layout and lifetime are covered by `SwifttyAppTests/MuxNativeTests`. These tests use real Metal and real shells, but run without a display link.

## Measurements

From `swift run -c release swiftmux-bench` (`mise run bench-swiftmux`): an in-process service behind real XPC, with real PTY shells and a 32 MiB corpus of SGR, UTF‑8 and wide text.

| Measure | Result |
|---|---|
| Parser throughput, detached pane | 230 MiB/s |
| Parser throughput, attached 200×50 client | 271 MiB/s (60 Hz export cap: 7 frames during the run) |
| Input → frame latency (XPC, PTY echo, export, decode) | p50 1.43 ms, p95 1.55 ms, p99 1.63 ms |
| 200×50 frame | 103 KiB; export+encode p50 0.58 ms; decode+validate+import p50 0.66 ms; GPU render p50 1.03 ms |
| 512×256 frame (dimension limit) | 1.3 MiB; export+encode p50 4.48 ms; decode+validate+import p50 5.17 ms; GPU render p50 5.50 ms |
| 1 MiB paste (paste limit, 32 KiB chunks under writer credit) | 129 ms |
| Literal search over 10,000 history rows (row limit) | 8.96 ms |
| 32 noisy panes, no client (pane limit) | service CPU 334 % (about 32 continuous streams); footprint 200 MiB |
| 32 noisy panes, 1 visible | service CPU 336 %; footprint 346 MiB; 55 frames/s delivered |
| 32 visible noisy panes in one 512×255 tab | service+client CPU 422 %; footprint 624 MiB; 1,836 frames/s (about 57 per pane, at the 60 Hz cap) |
| Idle footprint | 39 MiB |

History budget: each pane gets up to 16 MiB and 10,000 rows from the shared 128 MiB pool. A 1 MiB minimum is held back for each pane that could still be created, so the total of all pane limits never exceeds 128 MiB (`HistoryBudgetTests`).

The footprint covers the whole bench process, so the client that decodes every frame is included. The JSON codec takes roughly 10 ms per frame at the 512×256 limit, which makes it the first candidate for a compact codec or deltas (spec §4).

`FrameTimeTests` measures optimized code. It is now enabled only in optimized builds (`swift test -c release`), where it passes with p95 0.68 ms and 1.77 ms. Debug builds skip it rather than failing.
