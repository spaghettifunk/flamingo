# AGENTS.md

## Project Overview

Flamingo is a Zig terminal text editor. The codebase includes editor buffer, rendering, syntax, explorer, search, LSP, and perf modules.

## Commands

Use the commands defined by `build.zig` and the Zig toolchain:

- Build: `zig build`
- Run: `zig build run`
- Run with args: `zig build run -- <args>`
- Test: `zig build test`
- Perf benchmark: `zig build perf`
- Format changed Zig files: `zig fmt <files>`

Do not invent extra build, test, or formatting commands unless the repository adds them.

## Engineering Constraints

- Keep compatibility with Zig 0.16.0 (`build.zig.zon` sets this as the minimum).
- Prefer small, reviewable patches. Avoid broad rewrites unless explicitly requested.
- Preserve ownership semantics when changing buffers, editor state, runtime queues, LSP data, or syntax state.
- Be explicit about allocator ownership: document whether returned memory is borrowed or owned, and make deinit paths clear.
- Avoid allocations in render hot paths. Precompute, reuse buffers, or move work out of the frame path where practical.
- Do not block the event loop with parsing, LSP, filesystem scanning, or other long-running work.

## Architecture Notes

- Rendering should continue moving toward virtual-screen diffing.
- Legacy rendering should not gain new features unless needed for compatibility or an explicitly requested fix.
- Syntax parsing should remain async/background where possible.
- Convert LSP JSON into typed editor state before using it in UI code.

## Validation

- Run `zig build` and `zig build test` after code changes when practical.
- Run narrower validation first if a change is risky or localized, then the full build/test commands before finishing.
- Summarize what changed in the final response.
- Mention any commands or tests that could not be run.
- If a new command or keybinding is added, update `docs/keybindings.md`.
- Update the documentation `docs` if necessary
