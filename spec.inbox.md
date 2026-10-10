# Swiftty unified service, attention inbox and deep links

**Status:** Implemented on `feat/unified`  
**Date:** 2026-10-10  
**Builds on:** [spec.multiplexer.md](spec.multiplexer.md) (SwiftMux) and [spec.roaming.md](spec.roaming.md) (RST/1 roaming)  
**Language:** Swift 6.4 (Swift 6 mode); deployment minimum 27.0 per Apple platform

This document covers only what this branch adds on top of the two merged
feature branches. Those branches built SwiftMux and RST/1 roaming as separate
products. This branch joins them into one service, then adds the OSC 7501
attention inbox and deep links on top. Everything else (the SwiftMux
workspace model, PTY launcher, frames and native window, plus RST/1 framing,
SSH/SFTP, QUIC pinning and the clients) is specified in the two documents
above and is unchanged unless stated here.

## 1. One service, two transports

`swiftmux-agent` is the only process that owns shells, PTYs and terminal
state. It serves:

- **Local:** the native Swiftty app over authenticated per-user XPC (SMX/1),
  as before.
- **Remote:** SSH bootstrap plus QUIC RST/1, hosted in the same process by
  `TerminalHost.RoamingHost`. The RST/1 host no longer spawns shells; that
  code (`HostPTY` and `HostTerminalSession`) has been removed.

**Invariants:**

- Losing a client or a network path never ends a shell the service owns.
- A workspace has at most one interactive writer, whatever the transport.
- Remote clients attach to existing workspaces; they never start a duplicate
  PTY for one.

### 1.1 Roaming configuration

- **When roaming is on:** the agent serves roaming when a configuration
  exists. It looks first at `--roaming-config PATH`, then
  `$SWIFTMUX_ROAMING_CONFIG`, then
  `~/Library/Application Support/SwiftMux/roaming/config.json`.
- **Required fields:** the configuration must name `bindAddress` and
  `advertisedHost` explicitly. `port` defaults to 51222.
- **Turning it off:** `--no-roaming` disables roaming.
- **Agent lifetime:** while roaming is on, the agent never takes the idle
  exit. The agent property list sets `RunAtLoad`, so the listener is up
  after login without the app running.
- **State directory:** the owner-only directory
  (`…/SwiftMux/roaming`, mode 0700) holds the control socket and the QUIC
  TLS identity.

### 1.2 Bootstrap helper

`swifttyd` is reduced to the fixed, no-PTY helper that sshd runs:

- `swifttyd bootstrap --stdio` reads one length-prefixed request envelope.
  It relays the envelope to the service's control socket and writes back
  exactly one response envelope.
- `swifttyd status` sends a `list` request to report whether roaming is
  available.
- It refuses to run as root and owns no sessions.
- The `serve`, `install` and `uninstall` commands are removed.

### 1.3 Identity mapping

| RST/1 | SwiftMux |
|---|---|
| `SessionID` (16 bytes) | `WorkspaceID` (UUID bytes) |
| Grant `serverInstanceID` | `MuxService.instance` (the one service epoch) |
| Displayed screen | Active pane of the workspace's active tab |

A grant's session ID is the authorized workspace ID. `list` returns the
service's workspaces, including ones the Mac app created, most recent first.
It is capped by the RST/1 list limit.

### 1.4 In-process SMX client

Each RST/1 attachment reaches the service through `MuxLocalConnection`, an
SMX client inside the service process.

- **Same rules as XPC.** Leases, takeover fencing and the input ledger apply
  exactly as they do for XPC clients.
- **No encoding.** Messages travel as values. In-process clients may not
  subscribe to frames. Instead they get change notifications
  (`LocalClientSink.onPaneChanged`). They export screens with
  `MuxService.inspect(pane:)`, which runs in the pane's own queue order, so
  every byte parsed before the export, including final output after exit, is
  included.
- **Lease holder.** The lease records `LeaseHolder{transport: .remote}`.

### 1.5 Roaming session (`RoamingSession`)

`RoamingSession` holds the RST/1 side of one workspace:

- the writer and its `HostInputLedger`;
- the attachment epoch;
- the resize and screen revisions;
- snapshot scheduling.

It does not hold the shell.

- **Attach:**
  1. Fence the previous RST/1 attachment.
  2. Release its lease. If input is in flight, release only after that input
     is answered, so its outcome is known.
  3. Request `attach` on the workspace.
  4. On success, send `Attached` and a full snapshot.
- **Takeover:** a client gets a takeover only when it resumed with
  `takeover: true`. In that case a `leaseHeld` refusal leads to
  `takeover(expectedLease:)`, naming the generation it just listed. Without
  the flag, a held workspace returns `writerBusy`.
- **Input:** admitted RST/1 operations go to the pane one at a time, in
  ledger order. Each RST/1 sequence is acknowledged after the service admits
  it to the pane's ordered writer.
  - `committedText` becomes `MuxInput.text`.
  - `key` becomes `MuxInput.key`.
  - `paste` becomes `MuxInput.paste`.
  - `resize` becomes `setGeometry` for the active pane.
  - **Retries:** after `resourceLimit` or a stale layout/geometry error, the
    host retries; nothing was written.
  - **Any other error:** the host stops admitting input and never reports the
    failed operation as applied.
- **Lease loss:** if another frontend takes over, the RST/1 attachment fails
  with `writerBusy`. If the workspace ended, the client receives
  `terminated`.
- **Exit:** when the active pane exits, the client receives `sessionExited`
  followed by the final retained screen.

### 1.6 Grants and retention (`SessionRegistry`)

- **Create:** a new workspace with one pane and `remainOnExit`, started from
  `RoamingHost.defaultLaunch()` (a login shell with the agent's
  `PATH`/`USER`/`LOGNAME`/`SHELL`/`LANG`/`TMPDIR`).
- **Resume:** works for any existing workspace. It issues a fresh token and
  revokes the previous one. It keeps the writer only when the client names
  the current writer.
- **Remote authorization is separate from shell lifetime:**

  | Grant state | Expiry | What happens to the workspace |
  |---|---|---|
  | Reserved, never attached | 60 s | Ended only if this host created it |
  | Detached | 24 h | Grant revoked; the workspace keeps running |
  | Exited | 5 min | Ended if this host created it |

- **Terminate:** an explicit `terminate` ends the workspace.

`BootstrapRequest.takeover` is an optional field. Older clients omit it.

### 1.7 Launcher fix

If `openpty` or `pipe` returns fd 3 or 4, `PaneLauncher` now duplicates it to
fd 5 or above before spawning. Previously, `dup2(3, 3)` kept close-on-exec,
and crossed duplicates could overwrite each other, so the child received a
closed or wrong fd 3/4.

## 2. Leases, takeover and input (SMX/1 additions)

### 2.1 Per-workspace lease

- **Limits:** each workspace has at most one lease, and each client holds at
  most one.
- **Attach:** attaching a held workspace fails with `leaseHeld`.
- **Lease generation:** every grant increments a per-workspace lease
  generation. `WorkspaceSummary` carries `leaseGeneration` and
  `leaseHolder{transport, frontend, since}`.
- **`takeover(selector, expectedLease:)`:**
  - Succeeds only if `expectedLease` equals the current generation;
    otherwise it fails with `staleRevision`.
  - The old holder is fenced before the new lease exists: its pastes close,
    its attachment ID stops admitting input, and it receives `detached`.
- **`switchWorkspace`:** moves a lease only to a workspace no one else holds.
- **`detachActive`:** releases every lease and notifies the holders. It is
  used by the update barrier and `swmux detach`.

### 2.2 Metadata without a lease

- **`observeWorkspaces(Bool)`:** returns the workspace list and then pushes
  `workspaces` events whenever it changes, including lease changes.
- **Inbox commands (§3.4):** also need no lease.
- **Never resizes:** observation never resizes panes.

### 2.3 Input ledger

- **Sequences:** `InputRecord.sequence` is per attachment, starts at 1 and
  rises by one. The client resets it on every `attached` reply.
- **Duplicates:** a sequence below the next expected one is acknowledged
  again without being written.
- **Gaps:** a gap fails with `inputGap` and consumes nothing.
- **Outcomes:** every in-order record consumes its sequence, whatever its
  outcome.
- **Bounded paste:** `MuxInput.paste(String)` is a bounded paste of at most
  `maxPasteChunkBytes`. The service admits or refuses it whole and brackets
  it according to the pane's modes.

New error codes: `leaseHeld`, `staleRevision`, `inputGap`.

## 3. OSC 7501 attention inbox

### 3.1 Engine

`PaneRuntime` turns on program status for every pane, with a 64-record cap
(`programStatusCapacity`, clamped to 64–256). The pane publishes only once
per read turn, so a single turn can contain several transitions.

**Journal.** `ProgramStatusStore` keeps an opt-in bounded journal so those
transitions survive. `TerminalState.takeProgramStatusJournal()` returns:

- the ordered changes:
  - `.report(record)`;
  - `.removed([ids])`, from clear, prompt, exit or eviction;
  - `.reset`, from RIS;
- a `truncated` flag;
- the current snapshot.

When the journal overflows, it keeps only a `.reset` if one happened.

**Terminal epoch.** A pane gets a new `TerminalEpochID` when it is created
and at every RIS. A batch that contains a reset is split at the reset. The
final status is published before `.finished`.

### 3.2 Reducer (`MuxAttention.AttentionInbox`)

`AttentionInbox` is a plain value type with three separate models:

1. the current reported status of each record;
2. attention occurrences, each tracking seen, snoozed and resolution
   (`open`, `resolved`, `superseded`, `reviewed`, `paneExited`);
3. at most one open failure and one open result per source.

**Identity.** An item is identified by `AttentionSource{serviceEpoch, pane,
terminalEpoch, recordPath, recordIncarnation}` plus an `OccurrenceID`. It is
never keyed by program name or message.

- `recordIncarnation` is a counter within the pane's epoch. Recreating a path
  after it was removed therefore makes a new source.
- A new terminal epoch resolves the records of the old epoch.

| Transition | Result |
|---|---|
| `blocked` (permission/question/auth) | New `needsYou` occurrence |
| `blocked` again, or progress | Same occurrence updated; no duplicate |
| `blocked → working` | Occurrence resolved |
| `blocked → working → blocked` | Second, distinct occurrence |
| `error` | Unreviewed failure retained |
| `done → working` | Current status is working; the latest result stays open |
| Prompt, exit, clear, RIS | Protocol lifecycle applied; silence alone resolves nothing |
| Pane exit | Final status reduced first, then open items become `paneExited` |

**Rules:**

- **Before coalescing.** Every transition is reduced before any coalescing.
  `takeUpdate(at:)` returns the pending changed and removed sets.
- **Seen and reviewed:**
  - `markSeen` never resolves an item.
  - `markReviewed` applies only to failures and results; it throws for a
    request.
  - Every acknowledgement must match all fields of the `AttentionReference`,
    so a late acknowledgement of an older occurrence cannot touch a newer
    one.
- **Snooze:** `snooze` until a date; it expires by the clock.
- **Counts:** `needsYou` counts distinct sources with a current unsnoozed
  request or an unreviewed failure. `results` counts open results.
- **Paging:** at most 100 rows per page, with an opaque cursor. Sections are
  `needsYou`, `results` and `all`.
- **Caps:**
  - 64 records per pane.
  - 16 MiB of decoded status text in total. Each item is charged its decoded
    text plus 256 bytes.
  - Eviction removes resolved history first, then the oldest results, then
    the oldest failures.
  - Up to 256 resolved occurrences are kept, so a stale reference can be
    answered as `stale` rather than `missing`.

### 3.3 Service (`InboxHub`)

- **Always fed.** The service feeds the reducer from every pane event,
  including hidden and detached panes and panes with no client connected. It
  calls `paneExited` before cleaning up a pane.
- **Coalesced updates.** Updates are flushed 16 ms after a change as
  `MuxEvent.inbox(InboxUpdate{revision, counts, changed, removed, resync})`.
- **Bounded subscribers:**
  - At most 16 subscribers.
  - A subscriber acknowledges each update with
    `ClientMessage.inboxAck(revision:)`.
  - A subscriber with 64 unacknowledged updates is skipped. Once it catches
    up, it gets one update with `resync: true` and should refetch.
- **Independence.** Inbox subscriptions are independent of frame
  subscriptions and leases.

### 3.4 Commands (no lease)

| Command | Reply |
|---|---|
| `subscribeInbox(Bool)` | `ok` |
| `inbox(InboxQuery)` | `inbox(InboxPage)` |
| `locateAttention(ref)` | `attention(AttentionLocation)`: availability, item, workspace, tab, pane, and `leaseHeldElsewhere` |
| `markSeen(ref)` | `ok` |
| `snooze(ref, until:)` | `ok` (nil `until` clears the snooze) |
| `markReviewed(ref)` | `ok` (refused for a request) |

`AttentionLocation.availability` is `available`, `stale`, `paneExited` or
`missing`.

### 3.5 Native macOS UI

- **Toolbar:** the SwiftMux window's toolbar shows the Needs-you badge.
- **Popover:** lists items as sanitized plain text, never markup or links.
  Showing an item marks it seen.
- **Open in Pane:**
  - For a pane in the window's own workspace, it focuses that pane.
  - For another workspace, it uses `switchWorkspace`.
  - If that workspace's lease is held elsewhere, it asks first and then uses
    `takeover`.
- **Mark Reviewed:** offered for failures and results only.
- **Snooze:** a waiting request has a Snooze menu: 15 minutes, 1 hour or
  tomorrow at 9:00 (local time), sent as `snooze(ref, until:)`. A snoozed
  row shows "Snoozed until …", sorts after unsnoozed items and offers
  **Unsnooze** (`until: nil`). The badge already excludes snoozed requests
  (§3.2).
- **Paging:** the window reads the first page (100 rows) of `needsYou` and
  `results`. **Load More** follows each section's `nextCursor`. A reload
  (subscribe, `resync`, stale item) starts again from the first page.
- **Failures are always shown.** `markSeen`, `snooze`, `markReviewed`,
  `inbox` paging, `locateAttention`, `switchWorkspace` and `takeover`
  report failures. A failure appears as a line in the popover while it is
  open. Once it has closed, a user-initiated command shows an alert, and a
  background one (subscribe, reload, mark seen on display) waits for the
  next time the popover opens.
  - A reply of `stale` or `missing` drops the item and rereads the inbox:
    "The program has already moved on from this request." /
    "This item is no longer available."
  - `leaseHeld` from `switchWorkspace` means another frontend attached in
    the meantime, so the takeover prompt is shown.
  - `staleRevision` from `takeover` means the lease moved while the user
    was deciding. Nothing is taken over, and the prompt is shown again for
    the new generation ("Control of workspace … changed while you were
    deciding").
  - The pane is focused only after the switch or takeover succeeded.
- **Never an approval channel.** Opening an item never types into the pane;
  OSC 7501 is status only.

## 4. Deep links and navigation

### 4.1 Typed destination (`MuxNavigation`)

**Destination.** `AttentionDestination` holds:

- `localHostProfileID`
- `serviceEpoch`
- `workspaceID` and `tabID?`
- `paneID`
- `terminalEpoch`
- `recordPath` and `recordIncarnation`
- `occurrenceID`
- `intent`: `review`, `result` or `reveal`

`recordPath` follows the OSC 7501 id grammar: at most 128 bytes and 8
segments, each segment 1–32 bytes. The empty string is the root record.

**Locator.** `AttentionLocator` is an opaque, non-secret encoding of a
destination: a versioned binary record of IDs only, written as base64url.

- It is at most 336 characters.
- Decoding rejects unknown versions, intents or flag bits; wrong lengths;
  trailing bytes; padding; non-canonical spellings; and invalid paths.
- It is not a credential. It contains no endpoint, hostname, username,
  password, key, token, terminal output, message text or command.

### 4.2 URLs (`AttentionLink`)

Two forms are accepted:

- `swiftty://attention/open?ref=<locator>`
- `https://<domain>/a/<locator>`, where `<domain>` must appear in the app's
  `SwifttyAssociatedDomains`. That list is empty by default.

Everything else is rejected, including:

- any other scheme or domain;
- links over 2 KiB;
- non-printable characters;
- user info, a port (an empty port included) or a fragment;
- an extra or repeated query parameter;
- an extra path component.

A link never supplies an endpoint to connect to.

### 4.3 Navigator (`AttentionNavigator`)

`AttentionNavigator` is a main-actor state machine. Its states are: `idle`,
`rejected`, `needsHostSelection`, `connecting`, `unavailable` (with retry),
`ready`, `stale`, `missing(serviceRestarted | notFound)`, `paneExited`,
`confirmTakeover`, `opening` and `opened`. It works in this order:

1. **Validate** the link (§4.2).
2. **Resolve the host** only from the recipient's configured hosts.
   Otherwise, ask the user to choose one of their own hosts.
3. **Connect, then check the epoch.** It checks the service epoch before
   looking anything up. A different epoch is `missing(serviceRestarted)` and
   never redirects to another item.
4. **Locate without a lease.** Any reply that is not the exact occurrence and
   pane is refused.
5. **Open in pane.** It always tries a plain attach first. If the lease is
   held elsewhere, it offers a takeover tied to the lease generation the user
   saw, and offers again if that generation moved. It never takes over
   silently.
6. **Show other outcomes:**
   - `paneExited` shows the retained result.
   - Offline is `unavailable`, which can be retried.
7. **Mark seen.** After the user views it, the navigator marks only the
   linked occurrence seen, at most once. A newer link cancels an older one,
   so a late result is dropped.

`MuxNavigationSMX.SMXAttentionService` maps the navigator onto `MuxConnection`
commands.

### 4.4 Platform routing

**Universal Link configuration.** Universal Links are off unless
`SWIFTTY_LINK_DOMAINS` is set. Nothing is deployed from this repository, so
every piece is generated from configuration and can be checked locally.

- **Domains:** `SWIFTTY_LINK_DOMAINS` is a comma-separated (or
  space-separated) list of hostnames. `Scripts/link-domains.sh` lowercases,
  deduplicates and validates them; an invalid name fails packaging and
  project generation. `SWIFTTY_LINK_MODE=developer` appends
  `?mode=developer` to each `applinks:` entry for development builds.
- **Unset means nothing.** With the variable unset or empty, no target has
  `com.apple.developer.associated-domains`, `SwifttyAssociatedDomains` is
  empty and only `swiftty://` links are accepted.
- **Association file:** `Scripts/make-aasa.sh [-o path] <team-id>
  <bundle-id>...` writes the `apple-app-site-association` JSON. Its one
  `applinks.details` entry lists `<team>.<bundle>` app IDs. Its
  `components` include only `/a/?*` and exclude `/a/*/*`, any query
  (`"?": "?*"`) and any fragment (`"#": "?*"`). The script validates the
  output with `python3 -m json.tool`, `plutil` and a structure check;
  `--check <file> [team bundle...]` re-validates a served copy. Each domain
  serves it at `/.well-known/apple-app-site-association`. The apps still
  validate every link (§4.2); the file only decides which URLs the system
  hands to the app.

- **macOS (native Swiftty):**
  - The package script registers the `swiftty` URL type. With
    `SWIFTTY_LINK_DOMAINS` set, it lists the domains in
    `SwifttyAssociatedDomains` and signs the app with
    `com.apple.developer.associated-domains` (`applinks:<domain>` each);
    unset, the app is signed with no entitlements.
    `SWIFTTY_PROVISIONING_PROFILE` is embedded as
    `Contents/embedded.provisionprofile`. macOS honours the entitlement
    only with such a profile, so the script warns without one.
  - `AppDelegate` handles `application(_:open:)` and web-activity
    continuation.
  - `AttentionLinkRouter` shows each state as an `NSAlert`.
  - `MuxWorkspaceController.reveal(pane:tab:)` focuses the pane.
  - A per-install "This Mac" host ID is kept in UserDefaults.
- **Roaming clients (iOS/iPadOS, Catalyst, visionOS, tvOS, MacClient):**
  - The `swiftty` scheme comes from `Apps/Config/AttentionLinks.plist`.
  - `.onOpenURL`, web-activity and Handoff-activity routing live in
    `Apps/Shared/AttentionLinkViews.swift`.
  - A sheet shows the destination states.
  - **Associated domains:** `Apps/project.yml` runs
    `Scripts/configure-links.sh` as its XcodeGen `preGenCommand`. The script
    writes `Apps/Config/Generated/` (gitignored):
    - `AttentionLinks.plist`, with `SwifttyAssociatedDomains` set to the
      domains;
    - `<Target>.entitlements` for MobileClient, MacClient, CatalystClient
      and VisionClient. Each holds the target's own
      `Apps/<Target>/<Target>.entitlements` keys (or an empty dictionary)
      and, only when domains are set, the associated-domains key.

    Those four targets point `INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS`
    at the generated files. `Apps/Config/AssociatedDomains.entitlements.template`
    documents the key and is referenced by no target.
  - **tvOS** keeps the committed `AttentionLinks.plist` (no domains) and no
    associated domains. tvOS has no browser to hand an https link to the
    app, so only `swiftty://` and Handoff apply there.
- **watchOS:**
  - `AttentionSummary` shows a category, an app name, counts and a relative
    time. Message text is hidden by default and program text is sanitized.
  - `AttentionHandoffRequest`, sent as activity `dev.swiftty.attention.open`,
    carries only a locator so a paired device can open the item. It never
    grants a lease or sends input.

## 5. Verification

These suites all pass with `mise exec -- swift test`:

- **`LeaseTests`:** independent leases, takeover generation and fencing,
  observers, and ledger duplicates and gaps.
- **`MuxAttentionTests` (24):** every transition row, acceptance scenarios
  12, 13 and 15, exact references, snooze, paging and caps.
- **`ProgramStatusJournalTests`.**
- **`InboxTests`:**
  - acceptance 14 (status with no client connected, then reconnect);
  - two rapid occurrences;
  - locate and markSeen;
  - lease held elsewhere;
  - final drain;
  - slow-subscriber resync.
- **`MuxInboxUITests`:**
  - badge, open marks seen, review clears results;
  - snooze hides a request from the badge and unsnooze restores it;
  - stale and missing items are reported and dropped;
  - Load More reads past the first page;
  - a takeover refused with `staleRevision` asks again, then focuses the
    pane;
  - snooze choices, error wording and paging cursors.
- **`MuxNavigationTests` (34):**
  - locator round trips, corruption and canonical encoding;
  - malformed links, plus 3,000 random mutations;
  - no secrets in locators or URLs;
  - every navigator branch;
  - the SMX adapter against an in-process service.
- **`HostSessionTests`, `SessionRegistryTests`, `ControlSocketTests` and
  `RoamingEndToEndTests`:** rerun against the unified service.
- **`UnifiedServiceTests`:**
  - a workspace created by the Mac app is listed remotely;
  - a remote attach is refused without takeover, and with takeover the Mac
    holder is fenced;
  - the same shell PID and environment;
  - the lease is released on remote detach.

**Manual smoke test:** `swiftmux-agent --roaming-config` followed by
`swifttyd status` succeeds through the control socket.

`Scripts/build-platforms.sh` builds every app target and records the
associated domains each one was given. `Scripts/make-aasa.sh --check`
validates an association file. No simulator or device has run link routing,
and no real domain has served an association file, yet.
