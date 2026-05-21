# Terminal

## Status

Partial.

## Overview

Flamingo includes an integrated terminal panel. On Linux and macOS, it starts a shell through a PTY. On unsupported platforms, it reports that the integrated terminal is not supported.

## How To Use It

| Action | Key |
| --- | --- |
| Toggle terminal | `ctrl+t` |
| Return focus to editor | `esc` |
| Scroll page up | `pageup` |
| Scroll page down | `pagedown` |
| Scroll to bottom | `shift+end` |

When focused, printable characters and common control/navigation keys are converted to PTY input bytes.

## Data And Configuration

No terminal-specific config keys are implemented.

The shell is selected from `$SHELL`; if empty or missing, Flamingo uses `/bin/sh`.

The terminal panel keeps up to `1000` scrollback lines.

## Implementation Notes

- Terminal panel model, PTY backend, ANSI handling: `src/editor/terminal_panel.zig`
- Terminal rendering: `src/editor/renderer/terminal_panel_view.zig`
- Input routing: `src/editor/input_router/dispatch.zig`
- Runtime events: `src/editor/runtime/event_queue.zig`

The PTY reader thread enqueues terminal output into the editor event queue. The main loop appends output and redraws if the panel is visible.

## Limitations

- PTY backend support is currently Linux and macOS.
- ANSI support is intentionally limited to common cursor, clear, and SGR sequences.
- Terminal input pass-through is not represented as command keybindings.

