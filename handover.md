# Code review handover

## Goal

The active, unbounded goal is **“code review each file until no issues worth fixing surface.”** Inventory coverage and passing tests do not prove completion.

`sec.md` is reserved for actual security stops that cannot be processed without cyber-program access. No such stop has arisen. Ordinary unresolved findings are in [fixme.md](fixme.md). The accepted `sec.md` SHA-256 is `8e55d3daa149de18a94b079e98a425677c82d3c5e5339146dd5842437f9cd37f`. The earlier hash `4f9bf679288282c92a71fb4a6b102f79d64edab3ee51eae40f04c8a6eff6bba3` is waived: the only byte difference is the backlog link naming `fixme.md`.

## Working rules

- Repository: `/Users/chr33s/Developer/code/chr33s/swiftty`. Use Swift 6.4 through `mise exec --`. Format with `xcrun swift-format`, configuration `.swift-format`, and strict lint.
- Preserve pre-existing uncommitted work. No reset, commit, or deployment has been requested.
- Do not spawn agents unless the user asks. Do not signal other-project processes. An orphan `iso-sandbox` Swift test helper, PID 46043, was observed and left alone.
- Gate tests on a terminal successful build. Products are under `.build/out/Products/{Debug,Release}`. Release test builds need `--build-tests -Xswiftc -enable-testing`.
- A timeout is not a pass and is not a reason to restart a live run. A later green run does not close a historical failure.
- Do not widen deadlines, shrink payloads, recreate `sec.fix.md`, or change signing policy.

## Tracking

- [fixme.md](fixme.md): unresolved ordinary findings.
- [sec.md](sec.md): security-stop ledger only.
- `.build/code-review-progress.json`: pass 491 is recorded. The review status stays active.

## Remaining work

Publisher recovery, preview ownership, and the 15-second default for a non-finite refresh timeout are recorded. Paired-device continuity, physical backup or migration, signing, and Handoff were not run.

The open findings in `fixme.md` stay open: the native OSC empty colour reply, the launcher failure before scroll, the socket deadline, the oversized XPC record, the QUIC reset and rejected-stream failures, the SSH setup delay, the signing-query fallback, the SFTP presentation lifecycle, and the named deferred findings. Real-SSH, platform, device, and deployment gates remain.
