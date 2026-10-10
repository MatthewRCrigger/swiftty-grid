# SwiftMux: acceptance and measurement record

Branch `feat/swiftmux`, 2026-10-10. Host: Apple silicon MacBook Pro, 18 cores, macOS 27.0.1 (26A434). Toolchain: Swift 6.4 (swift-6.4-RELEASE), Xcode 27 SDK. Only this combination has been built and tested.

## Acceptance gates (spec §10)

| Gate | Evidence |
|---|---|
| C1 Compiler and package | Debug and release builds pass. `Scripts/package-swiftmux.sh` produces an ad-hoc signed `Swiftty.app`, and `codesign --verify --strict` passes. `swiftty --swiftmux-agent register` moved the agent from `notFound` to `enabled` through `SMAppService`, and launchd listed the job as submitted by `smd`. `unregister` set it to `notRegistered` and launchd removed the job. A Developer ID signature, and the team-ID peer requirement that comes with it, have not been tested. |
| C2 PTY/job control | `ServiceTests.controllingTerminalAndJobControl`: `tty`, `/dev/tty`, session leadership and Ctrl‑C (exit status 130). |
| C3 Lifetime | Packaged app with the registered agent: the service instance, shell PID and background-job PID were unchanged after the app was Force Quit (SIGKILL), quit normally and crashed (SIGSEGV). `swmux end` ended only its target. `reattachKeepsSameShell` covers client death and reattachment to the same shell, `TerminalClientTests` covers TTY detach, and the native test "splits, divider ratios and close detach keep the shell" covers closing the window. |
| C4 Completion | `naturalExitDrainsFinalOutput` (final output and exit status). `lateSpawnIntoEndedPaneIsReaped`. Forced close is bounded: SIGHUP, then SIGKILL after 2 s, and the forced kill is logged. |
| C5 Terminal behaviour | Engine parity in `BridgeTests` (wide, emoji, combining, SGR and underline colours, wraps). `detachedPanesStillAnswerQueries` (DA reply with no frontend attached). Existing Swiftty engine suites. |
| C6 Geometry and identity | `staleGeometryAndAttachmentAreRejected`, `splitZoomAndEndPane`, `incompatibleVersionIsRejected`, and the native split and divider test. |
| C7 Input and paste | `bracketedPasteAndCancelOnDisconnect`, ordered `enqueue`, and the native IME test (text delivered exactly once). Nothing is replayed automatically. |
| C8 Bounds and fairness | `slowClientStaysBoundedAndResponsive`, `inputBeyondWriterCreditIsRejected`, `paneLimitRejectsExcessCreation`, and the 32-pane load below. |
| C9 Owned frames and history | `BridgeTests` (malformed frames rejected), `historyScrollAndSearch` (a stale address is refused), and the native frozen-selection test. |
| C10 Registration and upgrades | `UpdateTests`: staging changes nothing, cancelling restores admission, a barrier timeout preserves sessions, and the update follows the ordered barrier. A wrong-version client gets an explanation instead of replacing the running service. |

Frontend gates: the decoder, diff renderer and full client are exercised against a fake outer terminal parsed by the Swiftty engine (`TerminalFrontendTests`). Native rendering, IME, selection, accessibility, layout and lifetime are covered by `SwifttyAppTests/MuxNativeTests`. These tests use real Metal and real shells, but run without a display link.

## Measurements

From `swift run -c release swiftmux-bench`: an in-process service behind real XPC, with real PTY shells and a 32 MiB corpus of SGR, UTF‑8 and wide text.

| Measure | Result |
|---|---|
| Parser throughput, detached pane | 233 MiB/s |
| Parser throughput, attached 200×50 client | 297 MiB/s (60 Hz export cap: 7 frames during the run) |
| Input → frame latency (XPC, PTY echo, export, decode) | p50 1.41 ms, p95 1.53 ms, p99 1.65 ms |
| 200×50 frame | 103 KiB; export+encode p50 0.58 ms; decode+validate+import p50 0.67 ms; GPU render p50 1.10 ms |
| 512×256 frame (limit) | 1.3 MiB; export+encode p50 4.29 ms; decode+validate+import p50 5.13 ms; GPU render p50 5.43 ms |
| 32 noisy panes, no client | service CPU 334 % (parsing about 32 continuous streams); footprint 222 MiB |
| 32 noisy panes, 1 visible | service CPU 337 %; footprint 368 MiB; 55 frames/s delivered |
| Idle footprint | 39 MiB |

The footprint covers the whole bench process, so the client side is included. The JSON codec stays well inside a 16.7 ms frame at typical sizes, but takes roughly 10 ms per frame at the 512×256 limit. That makes it the first candidate if a compact codec or delta encoding is needed (spec §4).

The existing `FrameTimeTests` thresholds hold only for optimized builds. In release they pass (p95 0.68 ms and 1.77 ms); in debug they fail on `main` as well.
