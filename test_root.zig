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
    _ = @import("src/editor/commands.zig");
    _ = @import("src/editor/keybindings.zig");
    _ = @import("src/editor/command_popup.zig");
    _ = @import("src/editor/global_search.zig");
    _ = @import("src/editor/help.zig");
    _ = @import("src/editor/git_status.zig");
    _ = @import("src/editor/git_graph.zig");
    _ = @import("src/editor/git/repository.zig");
    _ = @import("src/editor/git/diff_model.zig");
    _ = @import("src/editor/git/unified_diff_parser.zig");
    _ = @import("src/editor/git/diff_service.zig");
    _ = @import("src/editor/git/workspace_diff.zig");
    _ = @import("src/editor/agent/session.zig");
    _ = @import("src/editor/agent/backend.zig");
    _ = @import("src/editor/agent/provider_registry.zig");
    _ = @import("src/editor/agent/manager.zig");
    _ = @import("src/editor/agent/workspace_guard.zig");
    _ = @import("src/editor/agent/context.zig");
    _ = @import("src/editor/agent/prompt_templates.zig");
    _ = @import("src/editor/agent/context_builder.zig");
    _ = @import("src/editor/agent/tools.zig");
    _ = @import("src/editor/agent/tool_executor.zig");
    _ = @import("src/editor/agent/readonly_planner.zig");
    _ = @import("src/editor/agent/proposal.zig");
    _ = @import("src/editor/agent/proposal_manager.zig");
    _ = @import("src/editor/agent/proposal_apply.zig");
    _ = @import("src/editor/agent/mock_implementation.zig");
    _ = @import("src/editor/agent/openai_client.zig");
    _ = @import("src/editor/agent/backends/openai.zig");
    _ = @import("src/editor/tasks/command_parser.zig");
    _ = @import("src/editor/tasks/task.zig");
    _ = @import("src/editor/tasks/task_manager.zig");
    _ = @import("src/editor/workspace.zig");
    _ = @import("src/editor/todos.zig");
    _ = @import("src/editor/comments.zig");
    _ = @import("src/editor/multi_cursor.zig");
    _ = @import("src/editor/model/buffer.zig");
    _ = @import("src/editor/input_router/normal_sequence.zig");
    _ = @import("src/editor/actions.zig");
    _ = @import("src/editor/search.zig");
    _ = @import("src/editor/syntax.zig");
    _ = @import("src/editor/runtime/event_queue.zig");
    _ = @import("src/perf/perf.zig");
    _ = @import("src/editor/renderer/virtual_screen.zig");
    _ = @import("src/editor/renderer/git_graph_panel_view.zig");
    _ = @import("src/editor/renderer/git_diff_panel_view.zig");
    _ = @import("src/editor/renderer/task_panel_view.zig");
    _ = @import("src/editor/renderer/agent_panel_view.zig");
    _ = @import("src/editor/renderer/proposals_panel_view.zig");
    _ = @import("src/editor/terminal_panel.zig");
}
