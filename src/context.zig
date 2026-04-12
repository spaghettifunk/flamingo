const config = @import("config.zig");

pub const FlamingoContext = struct {
    log_level: u3,
    start_time: i64,
    config: config.Config,
};
