# Git Diff Panel

## Status

Partial.

## Overview

The Git Diff panel is a read-only workspace review view for unstaged working-tree changes. It lists changed files and renders unified diff hunks for tracked text files.

Open the panel:

```text
:gitdiff
```

## Controls

| Action | Key |
| --- | --- |
| Close panel | `q` or `esc` |
| Move selection up | `up` |
| Move selection down | `down` |
| Page up/down | `pageup`, `pagedown`, `ctrl+u`, `ctrl+d` |
| Open selected file | `enter` |
| Refresh | `r` |

Opening a selected diff row jumps to the corresponding new-file line when one is available.

## Data And Configuration

No Git Diff panel config keys are implemented.

Repository root detection starts from project root, explorer root, current file directory, then `.`. It supports normal `.git` directories and `.git` files used by worktrees.

## Implementation Notes

- Workspace diff model and parser: `src/editor/git/workspace_diff.zig`
- Command opening: `src/editor/command.zig`
- Input dispatch: `src/editor/input_router/dispatch.zig`
- Rendering: `src/editor/renderer/git_diff_panel_view.zig`

## Limitations

- The panel is read-only.
- Only unstaged working-tree diffs are rendered.
- Untracked files are listed with a placeholder instead of full added-file content.
- Very large diffs are truncated at 20,000 parsed diff lines.
