# Git Graph

## Status

Partial.

## Overview

The Git Graph panel is a read-only view of recent commit history for the nearest Git repository.

It runs `git log --graph --decorate=short --date=short --all --max-count=500` and parses the graph, refs, author, date, and subject into panel rows.

## How To Use It

Open the panel:

```text
:git-graph
:ggraph
```

Default controls:

| Action | Key |
| --- | --- |
| Close panel | `q` or `esc` |
| Move selection up | `up` |
| Move selection down | `down` |
| Page up/down | `pageup`, `pagedown` |
| First commit | `gg` |
| Last loaded commit | `G` |
| Refresh | `r` |
| Toggle details | `enter` |

## Data And Configuration

No Git Graph config keys are implemented.

Repository root detection starts from project root, explorer root, current file directory, then `.`. It supports normal `.git` directories and `.git` files used by worktrees.

## Implementation Notes

- Git Graph model and parser: `src/editor/git_graph.zig`
- Command opening: `src/editor/command.zig`
- Input dispatch: `src/editor/input_router/dispatch.zig`
- Rendering: `src/editor/renderer/git_graph_panel_view.zig`

## Limitations

- The panel is read-only.
- It depends on the `git` executable.
- It loads at most 500 commits.
- Empty repositories display no commit rows.
