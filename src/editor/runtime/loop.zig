const std = @import("std");
const terminal = @import("../../terminal.zig");
const perf = @import("../../perf/perf.zig");
const editor_lsp = @import("../lsp/editor_lsp.zig");
const editor_syntax = @import("../syntax_editor.zig");
const movement_coalesce = @import("movement_coalesce.zig");
const key_profile = @import("key_profile.zig");
const background = @import("background.zig");

const max_fifo_events_per_idle_tick = 8;
const syntax_parse_idle_delay_ns = 50 * std.time.ns_per_ms;

pub const InputKeyRead = struct {
    event: terminal.KeyEvent,
    read_start_ns: u64,
    read_elapsed_ns: u64,
    from_pending: bool = false,
};

pub const RuntimeKeyDispatch = struct {
    update_end_ns: u64,
    update_elapsed_ns: u64,
    movement_handled: bool,
};

pub fn run(editor: anytype) !void {
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();
    var stdout_buf: [0]u8 = .{};
    var stdin_buf: [1]u8 = undefined;
    var stdout_writer = stdout.writerStreaming(editor.io, &stdout_buf);
    var stdin_reader = stdin.readerStreaming(editor.io, &stdin_buf);

    try terminal.enableRawMode(editor.io);
    defer terminal.disableRawMode();

    const size = try terminal.getSize();
    editor.width = size.cols;
    editor.height = size.rows;

    try runWithIO(editor, &stdin_reader.interface, &stdout_writer.interface);
}

pub fn runWithIO(editor: anytype, reader: anytype, raw_writer: anytype) !void {
    var render_buffer = std.ArrayListUnmanaged(u8).empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(editor.allocator, &render_buffer);
    defer aw.deinit();
    const writer = &aw.writer;
    var last_input_ns: ?u64 = null;

    while (!editor.should_quit) {
        const loop_start = perf.nowNs();
        var metrics = perf.FrameMetrics{};

        var handled_input = false;
        var last_update_end_ns: ?u64 = null;
        var key_trace_storage = perf.KeypressTrace{};
        var key_trace: ?*perf.KeypressTrace = null;
        var key_start_ns: u64 = 0;
        var key_name_buf: [32]u8 = undefined;
        var input_count: usize = 0;
        while (input_count < 128) : (input_count += 1) {
            const key_read = try readInputKey(editor, reader, &metrics);
            const event = key_read.event;
            if (event.key == .None) break;
            handled_input = true;
            metrics.input_events += 1;

            var batch_count: usize = 1;
            var pending_key_stored = false;
            var coalesce_stop_reason: movement_coalesce.MovementCoalesceStopReason = .not_eligible;
            var coalescing_candidate: ?movement_coalesce.CoalescingCandidate = null;
            switch (movement_coalesce.movementCoalescingEligibilityBefore(editor, event)) {
                .eligible => |candidate| {
                    coalescing_candidate = candidate;
                    coalesce_stop_reason = .none;
                },
                .blocked => |reason| coalesce_stop_reason = reason,
            }

            if (editor.keypress_profiler.enabled) {
                key_start_ns = key_read.read_start_ns;
                const key_name = key_profile.formatKeyName(event, &key_name_buf);
                key_trace_storage = key_profile.initKeypressTrace(editor, event, key_name);
                key_trace_storage.read_ns = key_read.read_elapsed_ns;
                key_trace = &key_trace_storage;
            }

            const render_after_event = editor.shouldRenderAfterInputEvent(event);
            if (render_after_event) {
                metrics.cursor_move_events += 1;
            }

            const dispatch = try dispatchRuntimeKeyForLoop(editor, event, key_trace, &metrics);
            metrics.input_to_update_ns += dispatch.update_end_ns - key_read.read_start_ns;
            last_update_end_ns = dispatch.update_end_ns;
            last_input_ns = dispatch.update_end_ns;

            if (coalescing_candidate) |candidate| {
                if (!dispatch.movement_handled) {
                    coalesce_stop_reason = .not_eligible;
                } else if (movement_coalesce.coalescingStopReasonAfterMovement(editor, candidate.snapshot)) |reason| {
                    coalesce_stop_reason = reason;
                } else {
                    while (batch_count < movement_coalesce.max_movement_coalesce_batch_count and !editor.should_quit) {
                        const drain_read_start = perf.nowNs();
                        const next_event = terminal.readKey(reader) catch |err| {
                            coalesce_stop_reason = .read_error;
                            if (key_trace) |trace| trace.coalesce_stop_reason = coalesce_stop_reason.name();
                            return err;
                        };
                        const drain_read_elapsed = perf.elapsedNs(drain_read_start);
                        metrics.add(.input_poll, drain_read_elapsed);
                        if (key_trace) |trace| trace.read_ns += drain_read_elapsed;

                        if (movement_coalesce.coalescingStopReasonForNext(editor, candidate, next_event, batch_count)) |reason| {
                            coalesce_stop_reason = reason;
                            if (next_event.key != .None) {
                                std.debug.assert(editor.pending_key == null);
                                editor.pending_key = next_event;
                                pending_key_stored = true;
                            }
                            break;
                        }

                        batch_count += 1;
                        metrics.input_events += 1;

                        const next_render_after_event = editor.shouldRenderAfterInputEvent(next_event);
                        if (next_render_after_event) {
                            metrics.cursor_move_events += 1;
                        }

                        const next_dispatch = try dispatchRuntimeKeyForLoop(editor, next_event, key_trace, &metrics);
                        metrics.input_to_update_ns += next_dispatch.update_end_ns - drain_read_start;
                        last_update_end_ns = next_dispatch.update_end_ns;
                        last_input_ns = next_dispatch.update_end_ns;

                        if (!next_dispatch.movement_handled) {
                            coalesce_stop_reason = .not_eligible;
                            break;
                        }
                        if (movement_coalesce.coalescingStopReasonAfterMovement(editor, candidate.snapshot)) |reason| {
                            coalesce_stop_reason = reason;
                            break;
                        }
                    }
                    if (batch_count >= movement_coalesce.max_movement_coalesce_batch_count and coalesce_stop_reason == .none) {
                        coalesce_stop_reason = .max_batch;
                    } else if (coalesce_stop_reason == .none) {
                        coalesce_stop_reason = .no_pending_input;
                    }
                }
            }

            if (key_trace) |trace| {
                trace.batch_count = batch_count;
                trace.coalesced = batch_count > 1;
                trace.pending_key_stored = pending_key_stored;
                trace.coalesce_stop_reason = coalesce_stop_reason.name();
            }

            if (editor.should_quit) break;
            // Paint after the first input event, or after a bounded coalesced
            // movement batch when repeated movement keys were already queued.
            break;
        }

        if (!handled_input) {
            const events_start = perf.nowNs();
            try background.processBackgroundEvents(editor, max_fifo_events_per_idle_tick);
            metrics.add(.event_processing, perf.elapsedNs(events_start));

            const update_start = perf.nowNs();
            try editor_lsp.flushPendingLspChanges(editor, false);
            background.updateStatusClockDirty(editor);
            metrics.add(.update_state, perf.elapsedNs(update_start));
        }

        refreshTerminalSize(editor);

        if (editor.state.render_dirty) {
            if (key_trace) |trace| {
                trace.dirty = key_profile.keypressDirtyState(editor);
            }
            aw.clearRetainingCapacity();

            if (key_trace) |trace| {
                trace.reject = "none";
            }

            const previous_render_trace = editor.active_keypress_trace;
            editor.active_keypress_trace = key_trace;
            defer editor.active_keypress_trace = previous_render_trace;

            const frame_start = perf.nowNs();
            if (key_trace) |trace| {
                trace.render = .virtual;
                trace.render_path_reason = "virtual";
            }
            try editor.renderVirtual(writer, &metrics);
            const render_elapsed = perf.elapsedNs(frame_start);
            metrics.add(.build_frame, render_elapsed);
            if (key_trace) |trace| {
                trace.render_ns += render_elapsed;
            }
            metrics.render_kind = if (editor.state.force_full_render) .full else .partial;

            const flush_start = perf.nowNs();
            if (last_update_end_ns) |update_end| {
                metrics.update_to_flush_ns += flush_start - update_end;
            }
            const bytes = aw.written().len;
            try raw_writer.writeAll(aw.written());
            const write_elapsed = perf.elapsedNs(flush_start);
            metrics.add(.flush_output, write_elapsed);
            editor.runtime.updateFrameCapacityFps(metrics.get(.build_frame) + metrics.get(.flush_output));
            metrics.rendered = true;
            metrics.bytes_emitted = bytes;
            metrics.write_count = 1;
            if (key_trace) |trace| {
                trace.write_ns += write_elapsed;
                trace.bytes_emitted = bytes;
                trace.total_ns = perf.elapsedNs(key_start_ns);
            }
            editor.state.render_dirty = false;
            editor.state.force_full_render = false;
        }

        if (!handled_input) {
            const syntax_request_start = perf.nowNs();
            const can_queue_syntax = if (last_input_ns) |last_input|
                syntax_request_start - last_input >= syntax_parse_idle_delay_ns
            else
                true;
            if (can_queue_syntax) {
                try editor_syntax.queueSyntaxParseForCurrentTab(editor);
            }
            metrics.add(.update_state, perf.elapsedNs(syntax_request_start));
        }

        metrics.add(.total_loop, perf.elapsedNs(loop_start));
        editor.runtime.perf_sampler.observe(metrics);

        if (handled_input) {
            if (key_trace) |trace| {
                if (trace.total_ns == 0 and key_start_ns != 0) {
                    trace.total_ns = perf.elapsedNs(key_start_ns);
                }
                editor.keypress_profiler.observe(trace.*);
            }
        }

        if (!editor.state.render_dirty and !handled_input) {
            perf.sleepNs(1 * std.time.ns_per_ms);
        }
    }

    try editor_lsp.flushPendingLspChanges(editor, true);
    editor.runtime.perf_sampler.flush();
    aw.clearRetainingCapacity();
    try terminal.clearScreen(writer);
    try terminal.moveCursor(writer, 1, 1);
    try raw_writer.writeAll(aw.written());
}

pub fn readInputKey(editor: anytype, reader: anytype, metrics: *perf.FrameMetrics) !InputKeyRead {
    const read_start = perf.nowNs();
    if (editor.pending_key) |event| {
        editor.pending_key = null;
        return .{
            .event = event,
            .read_start_ns = read_start,
            .read_elapsed_ns = 0,
            .from_pending = true,
        };
    }

    const event = try terminal.readKey(reader);
    const read_elapsed = perf.elapsedNs(read_start);
    metrics.add(.input_poll, read_elapsed);
    return .{
        .event = event,
        .read_start_ns = read_start,
        .read_elapsed_ns = read_elapsed,
    };
}

pub fn refreshTerminalSize(editor: anytype) void {
    const size = terminal.getSize() catch return;
    if (editor.width == size.cols and editor.height == size.rows) return;
    editor.width = size.cols;
    editor.height = size.rows;
    editor.clampScroll();
    editor.markDirty(.full);
}

pub fn dispatchRuntimeKeyForLoop(
    editor: anytype,
    event: terminal.KeyEvent,
    key_trace: ?*perf.KeypressTrace,
    metrics: *perf.FrameMetrics,
) !RuntimeKeyDispatch {
    const input_handle_start = perf.nowNs();
    editor.last_input_movement_handled = false;
    {
        const previous_trace = editor.active_keypress_trace;
        editor.active_keypress_trace = key_trace;
        defer editor.active_keypress_trace = previous_trace;
        try editor.handleRuntimeKey(event);
    }
    const update_elapsed = perf.elapsedNs(input_handle_start);
    const update_end = perf.nowNs();
    if (key_trace) |trace| {
        trace.dispatch_ns += update_elapsed;
        key_profile.updateKeypressTraceAfterDispatch(editor, trace);
    }
    metrics.add(.update_state, update_elapsed);
    return .{
        .update_end_ns = update_end,
        .update_elapsed_ns = update_elapsed,
        .movement_handled = editor.last_input_movement_handled,
    };
}
