const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const assert = std.debug.assert;

pub const FileWriter = struct {
    file: std.Io.File,
    handle: posix.fd_t,
    io: Io,

    pub fn init(io: Io, path: []const u8) !FileWriter {
        assert(path.len > 0);
        const file = try std.Io.Dir.createFileAbsolute(
            io,
            path,
            .{
                .read = false,
                .truncate = true,
            },
        );
        return .{
            .file = file,
            .handle = file.handle,
            .io = io,
        };
    }

    pub fn deinit(self: *FileWriter) void {
        self.file.close(self.io);
    }

    pub fn sync(self: *FileWriter) !void {
        try self.file.sync(self.io);
    }
};
