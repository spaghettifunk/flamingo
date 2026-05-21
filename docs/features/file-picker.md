# File Picker

## Status

Implemented.

## Overview

The filesystem picker is used by dashboard flows for opening files, opening folders, choosing a new-file location, and creating a workspace in a folder.

## How To Use It

The picker is opened through dashboard actions:

- `New File`
- `Open File`
- `Open Folder`
- `Create Workspace`

Default picker controls:

| Action | Key |
| --- | --- |
| Move selection | `up`, `down` |
| Accept selection | `enter` |
| Cancel picker | `esc` |
| Go to parent or delete name character | `backspace` |
| Begin new-file name input | `space` in new-file location mode |
| Select highlighted folder | `space` in open-folder mode |
| Select current folder | `.` in open-folder mode |

When the picker is entering a new-file name, printable characters are appended to the name.

## Data And Configuration

No picker-specific config keys are implemented.

The picker skips `.`, `..`, `.git`, `.zig-cache`, and `zig-out`.

## Implementation Notes

- Picker state and filesystem traversal: `src/editor/filesystem_picker.zig`
- Picker help/render helpers: `src/editor/renderer/picker_help_popups.zig`
- Dashboard dispatch: `src/editor/input_router/dispatch.zig`
- File/folder effects: `src/editor/filesystem_ops.zig`

## Limitations

- The picker is not a general fuzzy file finder.
- File names are typed in a simple prompt phase; no completion is implemented there.
- Opening a folder replaces the current tab set.

