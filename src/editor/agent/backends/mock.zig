const backend = @import("../backend.zig");
const worker_mod = @import("../../runtime/mock_agent_worker.zig");

pub fn asBackend(worker: *worker_mod.MockAgentWorker) backend.AgentBackend {
    return .{
        .ctx = worker,
        .kind_value = .mock,
        .startSessionFn = startSession,
        .cancelSessionFn = cancelSession,
        .hasRunningSessionFn = hasRunningSession,
        .availabilityMessageFn = availabilityMessage,
    };
}

fn startSession(ctx: *anyopaque, request: backend.AgentRequest) backend.AgentBackendError!void {
    const worker: *worker_mod.MockAgentWorker = @ptrCast(@alignCast(ctx));
    return worker.startSession(request.session_id, request.mode, request.prompt, request.workspace_root, request.context);
}

fn cancelSession(ctx: *anyopaque, session_id: u64) void {
    _ = session_id;
    const worker: *worker_mod.MockAgentWorker = @ptrCast(@alignCast(ctx));
    worker.cancelRunning();
}

fn hasRunningSession(ctx: *anyopaque) bool {
    const worker: *worker_mod.MockAgentWorker = @ptrCast(@alignCast(ctx));
    return worker.hasRunningSession();
}

fn availabilityMessage(ctx: *anyopaque) ?[]const u8 {
    _ = ctx;
    return null;
}
