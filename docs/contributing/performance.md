# Performance

Flamingo is a terminal editor, so responsiveness depends heavily on input handling, rendering, buffer operations, background work, and terminal output volume.

## Benchmark Command

Run the current rendering benchmark with:

```bash
zig build perf
```

The benchmark is implemented in `../../src/perf_bench.zig` and support code under `../../src/perf/`.

Current benchmark behavior:

- Builds in ReleaseFast mode.
- Creates a synthetic 10,000-line Zig-like buffer.
- Measures full-frame virtual rendering for 240 frames.
- Measures cursor movement frames.
- Prints p50, p95, average, min, max, total time, frame count, and terminal bytes.

## Rendering Path

Important files:

- `../../src/editor/renderer/renderer.zig`
- `../../src/editor/renderer/editor_render.zig`
- `../../src/editor/renderer/virtual_screen.zig`
- Panel views under `../../src/editor/renderer/`

Performance guidance:

- Avoid allocations in per-frame rendering.
- Avoid recomputing expensive strings or layout state each frame.
- Keep panel-specific rendering separated from core editor rendering.
- Let the virtual screen diff terminal output instead of writing full frames when possible.

## Virtual Screen Diffing

The virtual screen keeps current and previous screen state and emits terminal output for changed cells. This is the direction the renderer should continue moving toward.

When changing rendering behavior, check both correctness and output volume. A visually correct change can still regress terminal throughput if it defeats diffing.

## Cursor Movement

Cursor movement can be a high-frequency path. Relevant areas include:

- Navigation helpers in `../../src/editor/navigation.zig` and `../../src/editor/navigation/viewport.zig`.
- Buffer cursor/edit behavior in `../../src/editor/model/buffer.zig`.
- Movement coalescing in `../../src/editor/runtime/movement_coalesce.zig`.
- Renderer cursor and viewport handling under `../../src/editor/renderer/`.

Keep cursor movement changes careful around viewport updates, syntax highlight refreshes, statusline updates, and redraw invalidation.

## Large Files

TODO: document tested large-file limits once they are defined.

Known current constraints visible in code:

- Global search skips files larger than 1 MiB.
- TODO code scanning skips files larger than 2 MiB.
- The perf benchmark uses a 10,000-line synthetic buffer, but this is a rendering benchmark rather than a general large-file guarantee.

## Background Work

Performance-sensitive background areas:

- Syntax parsing in `../../src/editor/runtime/syntax_worker.zig`.
- Git status refresh in `../../src/editor/runtime/git_status_worker.zig`.
- LSP process and message handling under `../../src/lsp/`.
- Global search and workspace scans in feature modules.
- Terminal PTY output handling in `../../src/editor/terminal_panel.zig`.

Avoid blocking direct input handling with long-running work. Prefer queued events, background workers, and coalesced updates.

## Instrumentation

Confirmed environment variables:

| Variable | Behavior |
| --- | --- |
| `FLAMINGO_PERF` | Enables perf sampler logging. |
| `FLAMINGO_PERF_KEYS` | Writes key timing data to `/tmp/flamingo-perf-keys.log`. |

Use these when investigating latency in interactive editor paths, then confirm broader rendering impact with `zig build perf`.

