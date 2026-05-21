# Search

## Status

Implemented.

## Overview

Buffer search searches the current open buffer with case-insensitive literal matching.

## How To Use It

From Normal mode:

| Action | Key |
| --- | --- |
| Open buffer search | `/` |
| Next match | `down` |
| Previous match | `up` |
| Accept search | `enter` |
| Cancel search | `esc` |
| Delete query character | `backspace` |

Printable characters extend the query. The active match moves the cursor.

## Data And Configuration

No search-specific config keys are implemented.

## Implementation Notes

- Search state and matching: `src/editor/search.zig`
- Search input dispatch: `src/editor/input_router/dispatch.zig`
- Search popup rendering: `src/editor/renderer/search_popups.zig`

`strictMatch` returns the first case-insensitive literal match per line and records matched byte indices for highlighting.

## Limitations

- Regex search is not implemented.
- Search is per-buffer, not across all open tabs.
- The current implementation finds the first match per line.

