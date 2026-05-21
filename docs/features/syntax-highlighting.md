# Syntax Highlighting

## Status

Implemented.

## Overview

Flamingo uses tree-sitter for syntax highlighting. Grammars are vendored and linked through `build.zig`.

Supported language detection by filename:

| Language | Extensions |
| --- | --- |
| Zig | `.zig` |
| Go | `.go` |
| TOML | `.toml` |
| YAML | `.yaml`, `.yml` |
| JSON | `.json` |
| Markdown | `.md`, `.markdown` |

Markdown also parses inline ranges with the vendored markdown-inline grammar.

## How To Use It

Open a file with a supported extension. Syntax parsing runs in the background and highlighting appears when the parse result is installed.

## Data And Configuration

No syntax-highlighting config keys are implemented.

Queries live under:

```text
src/editor/queries/
```

Vendored grammars live under:

```text
vendor/tree-sitter-*
```

## Implementation Notes

- Highlighter and tree-sitter integration: `src/editor/syntax.zig`
- Editor integration: `src/editor/syntax_editor.zig`
- Background parser worker: `src/editor/runtime/syntax_worker.zig`
- Runtime event queue: `src/editor/runtime/event_queue.zig`
- Line rendering: `src/editor/renderer/line_render.zig`

The highlighter tracks buffer revisions, stores committed parse results, prepares viewport-scoped highlight runs, and supports incremental reparsing when buffer edit deltas are available.

## Limitations

- Language support is fixed in source.
- Highlight styles are mapped from capture names to a compact internal style enum.
- TODO: document user theme customization once implemented.

