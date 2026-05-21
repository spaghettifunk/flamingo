# TODOs

## Status

Partial.

## Overview

The TODO panel combines code TODO scanning with manual workspace TODOs stored under `.flamingo/todos.json`.

Code TODO scanning recognizes these tags in supported comment styles:

```text
TODO
FIXME
HACK
BUG
NOTE
XXX
OPTIMIZE
PERF
```

Recognized comment markers include `//`, `#`, `--`, `<!--`, and `/*`.

## How To Use It

Open the panel:

```text
:todos
```

Default controls:

| Action | Key |
| --- | --- |
| Close panel | `q` or `esc` |
| Move selection | `up`, `down` |
| Refresh code TODOs | `r` |
| New manual TODO | `n` |
| Edit selected manual TODO | `e` |
| Delete selected manual TODO | `d` |
| Toggle selected manual TODO open/done | `x` |
| Open selected code TODO | `enter` or `o` |

Opening a code TODO opens the source file and jumps to the recorded location. Opening a manual TODO starts edit mode.

## Data And Configuration

Manual TODOs require a project `.flamingo/` directory. `:todos` creates it lazily when possible.

Manual TODO storage:

```text
.flamingo/todos.json
```

Storage shape is JSON with `version = 1` and an `items` array. Manual items store `id`, `title`, `body`, `status`, `created_at_unix_ms`, and `updated_at_unix_ms`.

Scanner limits:

| Limit | Value |
| --- | --- |
| Maximum code TODOs | `1000` |
| Maximum scanned file size | `2 MiB` |

The scanner skips `.flamingo`, `.git`, `node_modules`, Zig build artifacts, `target`, `dist`, `build`, and `.DS_Store`.

## Implementation Notes

- TODO model, scanner, JSON persistence: `src/editor/todos.zig`
- Panel command opening: `src/editor/command.zig`
- Panel input and prompts: `src/editor/input_router/dispatch.zig`
- Workspace marker helpers: `src/editor/workspace.zig`
- Rendering: `src/editor/renderer/todo_panel_view.zig`

## Limitations

- Manual TODO UI currently edits the title; the stored `body` field exists but is not exposed as a rich editor flow.
- Code TODO edits happen in source files, not in the panel.
- Scanning is synchronous when refreshed/opened.

