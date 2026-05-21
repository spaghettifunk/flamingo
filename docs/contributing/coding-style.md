# Coding Style

This page documents conventions visible in the current repository. It is not a complete style guide.

## General Zig Style

- Modules are grouped by subsystem under `src/`.
- Editor feature modules generally live directly under `src/editor/`.
- Rendering-specific code lives under `src/editor/renderer/`.
- Runtime and worker code lives under `src/editor/runtime/`.
- Tests live under `tests/` and are pulled together through `test_root.zig`.
- Public command names use canonical string identifiers from `src/editor/commands.zig`.

## Ownership And Allocation

Allocator ownership should be explicit.

Use the existing pattern of storing allocator references on state that owns dynamic data, then freeing owned strings, arrays, and nested structures in deinit paths. When returning memory from a helper, make it clear whether the caller owns the result or is borrowing data from editor state.

Areas where ownership mistakes are especially risky:

- Buffers and tabs.
- Runtime event payloads.
- LSP request/response data.
- Syntax parse results.
- TODO/comment workspace data.
- Renderer buffers and reusable scratch state.

## Error Handling

The codebase uses normal Zig error unions and `try` for propagation. Prefer returning errors to silently ignoring failures unless the existing feature deliberately degrades best-effort, such as optional Git metadata or optional LSP startup.

When a user-facing operation can fail, route the failure to the existing status/message path where practical.

## Commands And Keybindings

Command definitions should stay centralized in `src/editor/commands.zig`. Input routing should dispatch canonical commands rather than duplicating behavior across contexts.

When adding or changing commands:

- Add or update command metadata.
- Check supported contexts.
- Add default keybindings only when they are useful and conflict-free.
- Update `../reference/command-reference.md` and `../reference/keybinding-reference.md`.
- Update user-guide pages when the workflow changes.

## Rendering

Rendering code should avoid avoidable per-frame allocation. Move expensive or structural work out of the frame path where possible.

Prefer:

- Reusing buffers.
- Precomputing panel state after input or background events.
- Letting virtual-screen diffing handle terminal output changes.
- Keeping feature-specific rendering in feature-specific renderer modules.

## Background Work

Parsing, LSP, filesystem scanning, Git status, and terminal output can all affect responsiveness. Prefer the existing runtime/event queue patterns over synchronous work in input handling.

If a new feature needs background processing, look at the syntax worker and Git status worker before introducing a new concurrency pattern.

## Tests

Current tests live in `tests/` and are run through:

```bash
zig build test
```

For localized changes, add focused tests near the existing test category if there is an obvious match. Broaden coverage when changing shared behavior such as buffers, config validation, input routing, commands, or filesystem workflows.

