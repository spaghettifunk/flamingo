# Execution Tasks (for Codex)

## Phase 1: Measurement

- [ ] Add frame timing instrumentation
- [ ] Log timings every 60 frames
- [ ] Verify ReleaseFast build

## Phase 2: Rendering

- [ ] Implement virtual screen buffer
- [ ] Implement diff-based renderer
- [ ] Batch all terminal output into single buffer
- [ ] Ensure single flush per frame
- [ ] Skip rendering when no changes

## Phase 3: Highlighting

- [ ] Restrict highlighting to viewport
- [ ] Add line-level highlight cache
- [ ] Implement tree-sitter incremental edits

## Phase 4: Concurrency

- [ ] Move parsing to background thread
- [ ] Introduce versioned snapshots
- [ ] Ensure UI never blocks on parser

## Phase 5: Validation

- [ ] Measure FPS after each phase
- [ ] Test with large files (>10k lines)
- [ ] Verify typing latency

## Phase 6: Optional

- [ ] Evaluate piece table (only if needed)
