/// Save-confirmation dialog shown when the user tries to close a dirty buffer
/// via `:q` or Ctrl+W.  The popup holds a borrowed (non-owned) slice to the
/// buffer filename so that no allocation is required.
pub const SaveConfirmationPopup = struct {
    visible: bool = false,
    /// Borrowed reference to the current buffer filename, or null for unsaved
    /// buffers.  Callers must NOT free this slice – it is owned by the Buffer.
    filename: ?[]const u8 = null,

    pub fn open(self: *SaveConfirmationPopup, filename: ?[]const u8) void {
        self.visible = true;
        self.filename = filename;
    }

    pub fn close(self: *SaveConfirmationPopup) void {
        self.visible = false;
        self.filename = null;
    }

    /// Display name shown inside the popup (basename if a path is available).
    pub fn displayName(self: *const SaveConfirmationPopup) []const u8 {
        const fname = self.filename orelse return "unsaved buffer";
        // Walk backwards to find the last path separator.
        var i: usize = fname.len;
        while (i > 0) {
            i -= 1;
            if (fname[i] == '/' or fname[i] == '\\') return fname[i + 1 ..];
        }
        return fname;
    }
};

test "displayName returns basename" {
    const std = @import("std");
    var popup = SaveConfirmationPopup{};
    popup.open("/home/user/project/main.zig");
    try std.testing.expectEqualStrings("main.zig", popup.displayName());
    popup.close();
    try std.testing.expectEqualStrings("unsaved buffer", popup.displayName());
}
