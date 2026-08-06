const std = @import("std");
const assert = std.debug.assert;
const c = @import("libpq");

pub const PgCopyOut = struct {
    conn_handle: *c.PGconn,
    is_finished: bool,

    pub const Chunk = struct {
        ptr: [*c]u8,
        len: u32,

        pub fn slice(self: Chunk) []const u8 {
            assert(self.ptr != null);
            assert(self.len > 0);
            return self.ptr[0..self.len];
        }

        pub fn deinit(self: Chunk) void {
            assert(self.ptr != null);
            c.PQfreemem(self.ptr);
        }
    };

    pub const Status = union(enum) {
        chunk: Chunk,
        would_block,
        done,
        err: []const u8,
    };

    pub fn init(conn_handle: *c.PGconn) PgCopyOut {
        assert(c.PQstatus(conn_handle) == c.CONNECTION_OK);
        return .{
            .conn_handle = conn_handle,
            .is_finished = false,
        };
    }

    pub fn getSocketFd(self: *const PgCopyOut) std.posix.fd_t {
        const fd = c.PQsocket(self.conn_handle);
        assert(fd >= 0);
        return @intCast(fd);
    }

    pub fn consumeInput(self: *const PgCopyOut) !void {
        assert(!self.is_finished);
        if (c.PQconsumeInput(self.conn_handle) == 0) {
            return error.PostgresqlConsumeFailed;
        }
    }

    pub fn read(self: *PgCopyOut) Status {
        if (self.is_finished) return .done;

        var buf: [*c]u8 = null;
        const bytes_read = c.PQgetCopyData(
            self.conn_handle,
            &buf,
            1,
        );

        if (bytes_read > 0) {
            const len: u32 = @intCast(bytes_read);
            assert(buf != null);
            assert(len > 0);
            return .{
                .chunk = .{
                    .ptr = buf,
                    .len = len,
                },
            };
        } else if (bytes_read == 0) {
            return .would_block;
        } else if (bytes_read == -1) {
            if (!self.drainResults()) {
                return .would_block;
            }

            self.is_finished = true;
            return .done;
        } else {
            assert(bytes_read == -2);
            const err_msg = c.PQerrorMessage(self.conn_handle);
            return .{
                .err = if (err_msg != null) std.mem.span(err_msg) else "unknow libpq error...",
            };
        }
    }

    fn drainResults(self: *PgCopyOut) bool {
        while (c.PQisBusy(self.conn_handle) == 0) {
            const res = c.PQgetResult(self.conn_handle) orelse return true;
            c.PQclear(res);
        }
        return false;
    }
};
