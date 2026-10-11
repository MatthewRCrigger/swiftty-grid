# Ghostty behavior-check backlog

Upstream checks Swiftty can't cover yet because their features or APIs aren't
implemented. Each family is feature work first; confirm scope before starting.
Upstream references are Ghostty commit
[`a60e9e2`](https://github.com/ghostty-org/ghostty/tree/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src).

## OSC 133 click options

[Terminal.zig#L15659](https://github.com/ghostty-org/ghostty/blob/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src/terminal/Terminal.zig#L15659)

- [ ] `click_events=0/1/2` behavior.
- [ ] `cl` options, their precedence over `click_events`, and defaults.

## Rectangle checksums

[xt_checksum.zig#L234](https://github.com/ghostty-org/ghostty/blob/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src/terminal/xt_checksum.zig#L234),
[stream_terminal.zig#L5978](https://github.com/ghostty-org/ghostty/blob/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src/terminal/stream_terminal.zig#L5978)

- [ ] DECRQCRA enabled/disabled and XTCHECKSUM gating.
- [ ] Rectangle defaults, bounds, origin mode and clamping.
- [ ] Blank cells, attributes, wide characters and combining marks.
- [ ] Configured checksum defaults survive reset.

## Kitty clipboard

[stream_terminal.zig#L4543](https://github.com/ghostty-org/ghostty/blob/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src/terminal/stream_terminal.zig#L4543)

- [ ] Read/write transactions and response statuses.
- [ ] Malformed packets, size limits and chunked Base64.
- [ ] Permissions, one-time grants and reset cleanup.

## Kitty drag-and-drop

[stream_terminal.zig#L6706](https://github.com/ghostty-org/ghostty/blob/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src/terminal/stream_terminal.zig#L6706)

- [ ] Registration, queries, data delivery and callbacks.
- [ ] Registration survives reset.

## Extended input modes

[key_encode.zig#L2284](https://github.com/ghostty-org/ghostty/blob/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src/input/key_encode.zig#L2284),
[mouse_encode.zig#L646](https://github.com/ghostty-org/ghostty/blob/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src/input/mouse_encode.zig#L646)

- [ ] DECBKM Backspace.
- [ ] modifyOtherKeys encoding and modifier combinations.
- [ ] Application keypad key encoding and NumLock (mode tracking is done; the
      input API can't distinguish keypad keys or NumLock yet).
- [ ] Kitty Caps Lock modifier (`KeyModifiers` can't represent it).
- [ ] URXVT mouse encoding.
- [ ] SGR pixel-coordinate reporting.
