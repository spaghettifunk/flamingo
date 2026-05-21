# File Explorer

## Status

Implemented.

## Overview

The file explorer is a tree panel rooted at the active project folder. It can expand/collapse directories, open files, search paths, and start new-file, rename, and delete prompts for regular files.

## How To Use It

| Action | Key |
| --- | --- |
| Toggle explorer | `ctrl+b` |
| Cycle focus to/from explorer | `ctrl+e` |
| Move selection | `up`, `down` |
| Open file or toggle directory | `enter` |
| Start explorer search | `/` |
| Cancel explorer search | `esc` |
| Search backspace | `backspace` |
| New file from selected directory | `alt+n` |
| Rename selected file | `alt+r` |
| Delete selected file | `alt+delete` or `alt+backspace` |

When explorer search is active, printable characters update the search query and matching results are selected with `up`/`down`.

## Data And Configuration

| Config | Description |
| --- | --- |
| `[explorer].width_percentage` | Explorer width as a percentage of terminal width. Default: `20`. |

The explorer hides `.`, `..`, `.git`, `.zig-cache`, and `.DS_Store`. It displays Git status markers when a Git status snapshot is available.

## Implementation Notes

- Explorer model and render path: `src/editor/explorer.zig`
- Explorer actions: `src/editor/input_router/dispatch.zig`
- File operations: `src/editor/filesystem_ops.zig`
- Git status snapshot: `src/editor/git_status.zig`
- Width calculation: `src/editor/navigation/viewport.zig` and `src/editor/renderer/editor_render.zig`

## Limitations

- Folder rename is not supported in the explorer prompt.
- Delete operations only delete regular files through the current UI path.
- Explorer search is synchronous and literal case-insensitive matching.

