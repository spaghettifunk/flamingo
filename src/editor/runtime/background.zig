const std = @import("std");
const logz = @import("logz");
const syntax = @import("../syntax.zig");
const editor_lsp = @import("../lsp/editor_lsp.zig");
const editor_syntax = @import("../syntax_editor.zig");
const statusline = @import("../renderer/statusline.zig");

pub fn processBackgroundEvents(editor: anytype, max_fifo_events: usize) !void {
    var fifo_events_processed: usize = 0;
    while (fifo_events_processed < max_fifo_events) : (fifo_events_processed += 1) {
        const ev = editor.runtime.event_queue.tryPop() orelse break;
        const event = ev;
        switch (event) {
            .lsp_message => |msg| {
                defer editor.allocator.free(msg.plugin_name);
                defer editor.allocator.free(msg.message);
                try editor_lsp.handleLspEvent(editor, msg.plugin_name, msg.message);
            },
            .git_status_snapshot => |snapshot| {
                if (editor.state.git_snapshot) |*old| {
                    if (old.eql(&snapshot)) {
                        var duplicate = snapshot;
                        duplicate.deinit();
                        continue;
                    }
                }
                if (editor.state.git_snapshot) |*old| old.deinit();
                editor.state.git_snapshot = snapshot;
                editor.markDirty(.partial);
            },
            .git_diff_result => |result| {
                var owned = result;
                defer owned.deinit(editor.allocator);
                const explicit = owned.explicit;
                const status = owned.status;
                try editor.state.git_diff.applyRefreshResult(&owned);
                if (explicit) {
                    editor.setGitDiffRefreshStatus(status);
                }
                editor.markDirty(.partial);
            },
            .terminal_output => |output| {
                defer editor.allocator.free(output.bytes);
                editor.terminal_panel.appendOutput(output.bytes) catch |err| {
                    logz.err().fmt("msg", "failed to append terminal output: {any}", .{err}).log();
                };
                if (editor.terminal_panel.visible) editor.markDirty(.partial);
            },
            .terminal_exit => |exit| {
                editor.terminal_panel.markExited(exit.code) catch |err| {
                    logz.err().fmt("msg", "failed to record terminal exit: {any}", .{err}).log();
                };
                if (editor.terminal_panel.visible) editor.markDirty(.partial);
            },
            .syntax_parse_result => unreachable,
        }
    }

    var syntax_results = std.ArrayList(syntax.ParseResult).empty;
    defer syntax_results.deinit(editor.allocator);
    editor.runtime.event_queue.drainSyntaxResults(&syntax_results) catch |err| {
        logz.err().fmt("msg", "failed to drain syntax parse results: {any}", .{err}).log();
    };
    for (syntax_results.items) |*result| {
        defer result.deinit(editor.allocator);
        editor_syntax.handleSyntaxParseResult(editor, result) catch |err| {
            logz.err().fmt("msg", "failed to install syntax parse result: {any}", .{err}).log();
        };
    }
}

pub fn updateStatusClockDirty(editor: anytype) void {
    const minute = statusline.currentMinute(editor);
    if (minute != editor.last_status_minute) {
        editor.last_status_minute = minute;
        editor.markDirty(.partial);
    }
}
