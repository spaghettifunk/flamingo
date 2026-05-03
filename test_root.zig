const std = @import("std");

test {
    // Unit tests
    _ = @import("tests/terminal_test.zig");
    _ = @import("tests/config_test.zig");
    _ = @import("tests/buffer_extended_test.zig");
    _ = @import("tests/buffer_file_test.zig");
    _ = @import("tests/editor_test.zig");
    _ = @import("tests/buffer_test.zig");
    _ = @import("tests/actions_test.zig");
    _ = @import("tests/input_test.zig");
    _ = @import("tests/lsp_test.zig");

    // Core modules (to run internal tests)
    _ = @import("src/editor/editor.zig");
    _ = @import("src/editor/command.zig");
    _ = @import("src/editor/command_popup.zig");
    _ = @import("src/editor/global_search.zig");
    _ = @import("src/editor/model/buffer.zig");
    _ = @import("src/editor/actions.zig");
    _ = @import("src/editor/search.zig");
    _ = @import("src/editor/syntax.zig");
    _ = @import("src/editor/runtime/event_queue.zig");
    _ = @import("src/perf/perf.zig");
    _ = @import("src/editor/renderer/virtual_screen.zig");
}
