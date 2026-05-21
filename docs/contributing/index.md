# Contributing

This section is for developers changing Flamingo itself.

Flamingo is still an early-stage editor. Contributions should favor small, reviewable patches that fit the existing module boundaries and preserve ownership semantics around buffers, editor state, background work, LSP data, and rendering.

## Start Here

- [Architecture](architecture.md) gives a high-level map of the source tree.
- [Build and Test](build-and-test.md) lists the confirmed development commands.
- [Coding Style](coding-style.md) describes conventions already visible in the repository.
- [Debugging](debugging.md) covers practical local investigation.
- [Performance](performance.md) calls out paths that should stay allocation-aware and responsive.

## Contributor Expectations

- Keep changes scoped to the feature or bug being addressed.
- Prefer existing command, keybinding, state, renderer, runtime, and allocator patterns.
- Do not add external documentation tooling for ordinary docs updates.
- Avoid blocking the editor loop with parsing, LSP, filesystem scanning, Git commands, or other long-running work.
- Avoid allocations in render hot paths where practical.
- Run `zig build test` before finishing code changes when practical.
- Update documentation when behavior, commands, keybindings, config, or user workflows change.

