const logz = @import("logz");
const syntax = @import("syntax.zig");
const tab_mod = @import("model/tab.zig");

const Tab = tab_mod.Tab;

pub const TextSnapshot = struct {
    revision: u64,
    text: []u8,
};

pub fn handleSyntaxParseResult(editor: anytype, result: *syntax.ParseResult) !void {
    const tab = findTabBySyntaxBufferId(editor, result.buffer_id) orelse {
        logz.debug().fmt("msg", "dropping syntax result for closed buffer {d}", .{result.buffer_id}).log();
        return;
    };

    if (result.revision != tab.buf.revision) {
        logz.debug().fmt(
            "msg",
            "dropping stale syntax result for buffer {d}: result revision {d}, current revision {d}",
            .{ result.buffer_id, result.revision, tab.buf.revision },
        ).log();
        return;
    }

    const current_language = if (tab.buf.filename) |filename|
        syntax.languageFromFilename(filename)
    else
        null;
    if (current_language == null or current_language.? != result.language) {
        tab.syntax_requested_revision = null;
        logz.debug().fmt("msg", "dropping syntax result for changed language on buffer {d}", .{result.buffer_id}).log();
        return;
    }

    try tab.syntax_highlighter.installParseResult(result);
    tab.syntax_requested_revision = result.revision;
    editor.markDirty(.partial);
}

pub fn findTabBySyntaxBufferId(editor: anytype, buffer_id: u64) ?*Tab {
    for (editor.state.tabs.items) |*tab| {
        if (tab.syntax_buffer_id == buffer_id) return tab;
    }
    return null;
}

pub fn prepareSyntaxForViewport(editor: anytype, tab: *Tab, first_line: usize, last_line: usize, margin: usize) !void {
    _ = try tab.syntax_highlighter.prepareForAsyncBuffer(&tab.buf) orelse {
        tab.syntax_requested_revision = null;
        if (editor.active_keypress_trace) |trace| {
            trace.syntax_cache = syntax.ViewportCacheStatus.none.name();
        }
        return;
    };

    if (editor.active_keypress_trace) |trace| {
        trace.syntax_cache = tab.syntax_highlighter.viewportCacheStatusFromCommitted(first_line, last_line, margin).name();
    }
    try tab.syntax_highlighter.ensureViewportFromCommitted(first_line, last_line, margin);
}

pub fn takeTextSnapshot(editor: anytype, tab: *const Tab) !TextSnapshot {
    const revision = tab.buf.revision;
    const text = try tab.buf.toOwnedTextSnapshot(editor.allocator);
    return .{ .revision = revision, .text = text };
}

pub fn queueSyntaxParseForCurrentTab(editor: anytype) !void {
    const tab = editor.currentTab() orelse return;
    const language = try tab.syntax_highlighter.prepareForAsyncBuffer(&tab.buf) orelse {
        tab.syntax_requested_revision = null;
        return;
    };

    if (tab.syntax_highlighter.parsed_revision != tab.buf.revision and
        tab.syntax_requested_revision != tab.buf.revision)
    {
        const snapshot = try takeTextSnapshot(editor, tab);
        tab.syntax_requested_revision = snapshot.revision;
        editor.runtime.syntax_parse_worker.requestParse(tab.syntax_buffer_id, snapshot.revision, language, snapshot.text);
    }
}
