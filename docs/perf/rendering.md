# Rendering Optimization

## Problem

Current rendering likely redraws the entire screen each frame and flushes frequently.

## Target Design

### 1. Virtual Screen Buffer

Represent the screen as a grid:

```zig
const Cell = struct {
    ch: u21,
    fg: Color,
    bg: Color,
    style: Style,
};
```
