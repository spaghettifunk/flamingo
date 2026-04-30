# Flamingo Editor – Performance Plan

## Goal

Increase rendering performance from ~10 FPS to ≥100 FPS (≤10ms/frame).

## Current Architecture (simplified)

- Gap buffer for text storage
- Tree-sitter for syntax highlighting
- LSP integration
- Terminal-based rendering (ANSI)
- Single-threaded render loop (suspected)

## Primary Hypothesis

The FPS bottleneck is dominated by:

1. Full-screen redraw every frame
2. Excessive terminal I/O (many small writes / flushes)
3. Syntax highlighting (tree-sitter) on the UI thread
4. Recomputing highlights/layout for the entire file

NOT likely the main issue:

- Gap buffer vs piece table

## Strategy (ordered)

1. Measure frame phases precisely
2. Eliminate full redraws (diff-based rendering)
3. Batch terminal writes
4. Restrict work to viewport (render + highlight)
5. Move parsing/highlighting off the UI thread
6. Cache and incrementally update highlights
7. Re-evaluate data structures (only if needed)

## Frame Budget

- 100 FPS target → 10ms/frame
- 60 FPS acceptable → 16.6ms/frame

## Definition of Done

- Idle editor ≥100 FPS
- Typing latency < 16ms (no visible stutter)
- Scrolling smooth at ≥60 FPS on large files
