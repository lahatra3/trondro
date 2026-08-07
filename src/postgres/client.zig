const std = @import("std");
const c = @import("libpq");
const PgCopyOut = @import("copy.zig").PgCopyOut;

pub const PgClient = struct {
    conn_handle: *c.PGconn,

    pub fn init(conn_info: [:0]const u8) !PgClient {
        const conn = c.PQconnectdb(conn_info) orelse {
            std.log.err("[Postgresql]: connection allocation failed...", .{});
            return error.PostgresqlConnectionAllocationFailed;
        };

        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            std.log.err(
                \\ [Postgresql]: connection failed...
                \\  Error: {s}
            ,
                .{std.mem.span(c.PQerrorMessage(conn))},
            );
            c.PQfinish(conn);
            return error.PostgresqlConnectionFailed;
        }
        std.log.info("[Postgresql]: Connection succeeded ...", .{});

        std.log.info("[Postgresql]: Setting up non-blocking connection...", .{});
        _ = c.PQsetnonblocking(conn, 1);

        return .{
            .conn_handle = conn,
        };
    }

    pub fn deinit(self: *PgClient) void {
        std.log.info("[Postgresql]: closing connection...", .{});
        c.PQfinish(self.conn_handle);
    }

    pub fn startAsyncCopyOut(self: *PgClient, query: [:0]const u8) !PgCopyOut {
        const res = c.PQsendQuery(self.conn_handle, query);

        if (res == 0) {
            std.log.err(
                \\ [Postgresql]: sending copy out failed..."
                \\  Error: {s}
            ,
                .{std.mem.span(c.PQerrorMessage(self.conn_handle))},
            );
            return error.PostgresqlSendingQueryFailed;
        }

        return PgCopyOut.init(self.conn_handle);
    }
};
