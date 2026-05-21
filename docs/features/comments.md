# Comments

## Status

Partial.

## Overview

Comments let users create comment threads anchored to selected text in supported prose file types. Threads are stored in workspace JSON under `.flamingo/comments.json`.

Supported file extensions:

```text
.txt
.md
.markdown
.rst
.adoc
.org
```

## How To Use It

Create a comment from selected text:

```text
:comment
```

Open the comments panel:

```text
:comments
```

Reload comments:

```text
:comments refresh
```

Default panel controls:

| Action | Key |
| --- | --- |
| Close panel | `q` or `esc` |
| Move selection | `up`, `down` |
| Jump to selected anchor | `enter` |
| Reply to thread | `r` |
| Edit selected comment | `e` |
| Delete selected comment or thread root | `d` |
| Create new comment from current selection | `n` |
| Reload from disk | `R` |
| Next comment anchor | `]c` in Normal mode |
| Previous comment anchor | `[c` in Normal mode |

## Data And Configuration

Comments require a project `.flamingo/` directory. The comments flow creates it lazily when possible.

Storage path:

```text
.flamingo/comments.json
```

The JSON store has `version = 1` and a `threads` array. Threads include file path, anchor range, selected text, context, status, timestamps, and messages.

Comment authors are resolved from Git config first when inside a Git work tree:

```bash
git config user.name
git config user.email
```

If Git identity is unavailable, Flamingo falls back to:

```toml
[author]
name = "Your Name"
email = "you@example.com"
```

## Implementation Notes

- Comments model, storage, author resolution, anchor validation: `src/editor/comments.zig`
- Command entry: `src/editor/command.zig`
- Panel actions and prompts: `src/editor/input_router/dispatch.zig`
- Rendering: `src/editor/renderer/comments_panel_view.zig`
- Comment highlight ranges are used during line rendering.

Anchors are marked stale when the stored selected text no longer matches the current buffer at the saved range.

## Limitations

- Comments are limited to prose-like file extensions.
- Thread status currently only supports `open`.
- Anchors are range/text based; there is no advanced re-anchoring algorithm.
- Git author lookup runs external `git` commands.

