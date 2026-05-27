# Git Diff Gutter

## Status

Partial.

## Overview

The Git diff gutter marks unstaged working-tree changes for the current file when the file is inside a Git repository.

Markers appear as a thin colored rectangle beside the line numbers:

| Color  | Meaning               |
| ------ | --------------------- |
| Green  | Added line            |
| Yellow | Modified line         |
| Red    | Deleted line boundary |

Deleted lines no longer exist in the buffer, so the marker is attached to the nearest visible line boundary.

## How To Use It

Open a file inside a Git repository. Diff markers refresh when a file is opened and after a successful save.

Manual refresh:

```text
:gitdiff-refresh
:diff-refresh
:git-refresh
```

## Data And Configuration

No Git diff gutter config keys are implemented.

Repository detection walks upward from the file path and supports normal `.git` directories and `.git` files used by worktrees or submodules.

## Implementation Notes

- Repository discovery: `src/editor/git/repository.zig`
- Diff model/cache: `src/editor/git/diff_model.zig` and `src/editor/git/diff_service.zig`
- Unified diff parser: `src/editor/git/unified_diff_parser.zig`
- Runtime refresh worker: `src/editor/runtime/git_diff_worker.zig`
- Rendering: `src/editor/renderer/line_render.zig`

## Limitations

- Only unstaged working-tree changes are shown.
- Staged changes, staging operations, inline word diffs, and a full diff panel are not implemented yet.
- The feature depends on the `git` executable, but missing Git or non-Git folders should not prevent editing.
