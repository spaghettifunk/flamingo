# Frame Instrumentation

## Objective

Identify where time is spent per frame.

## Implementation

Add timing around each phase:

```zig
const t0 = std.time.nanoTimestamp();

try handleInput();
const t1 = std.time.nanoTimestamp();

try updateState();
const t2 = std.time.nanoTimestamp();

try highlightViewport();
const t3 = std.time.nanoTimestamp();

try buildFrame();
const t4 = std.time.nanoTimestamp();

try flushOutput();
const t5 = std.time.nanoTimestamp();
```
