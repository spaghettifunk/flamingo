# Global Search

## Status

Partial.

## Overview

Global Search is a project-wide search popup opened by the `:search` command. It searches file paths and, for queries with length 2 or more, scans text file contents.

## How To Use It

```text
:search
```

Default controls:

| Action | Key |
| --- | --- |
| Next result | `down` or `tab` |
| Previous result | `up` |
| Open selected result | `enter` |
| Cancel | `esc` |
| Delete query character | `backspace` |

Opening a path result opens the file at the top. Opening a content result opens the file and jumps to the matching row/column.

## Data And Configuration

No global-search-specific config keys are implemented.

The search skips these names:

```text
.
..
.git
.gitignore
zig-cache
.zig-cache
zig-out
zig-pkg
node_modules
target
build
.DS_Store
```

Confirmed limits:

| Limit | Value |
| --- | --- |
| Maximum results | `200` |
| Maximum file size for content scan | `1 MiB` |
| Maximum content matches per file | `10` |
| Maximum snippet length | `120` bytes |

## Implementation Notes

- Search model and scanner: `src/editor/global_search.zig`
- Command entry: `src/editor/command.zig`
- Input dispatch: `src/editor/input_router/dispatch.zig`
- Rendering: `src/editor/renderer/search_popups.zig`

## Limitations

- Search is literal ASCII case-insensitive matching, not regex.
- There is no background index or persistent search index.
- The scan is synchronous from the input path.
- Binary files are skipped for content results, but path matches can still appear.

