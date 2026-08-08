const std = @import("std");

pub const Config = struct {
    pg_conn_info: [:0]const u8,
    pg_copy_query: [:0]const u8,
    file_path: []const u8,

    pub const Error = error{
        MissingEnvironmentVariable,
        OutOfMemory,
    };

    pub fn load(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) Error!Config {
        const conn_info = env_map.get("PG_CONN_INFO") orelse {
            std.log.err("PG_CONN_INFO not found...", .{});
            return error.MissingEnvironmentVariable;
        };

        const source = env_map.get("DT_SOURCE") orelse {
            std.log.err("DT_SOURCE not found...", .{});
            return error.MissingEnvironmentVariable;
        };

        const sink = env_map.get("DT_SINK") orelse {
            std.log.err("DT_SINK not found...", .{});
            return error.MissingEnvironmentVariable;
        };

        const col_sep = env_map.get("DT_COL_SEP") orelse "|";

        const pg_conn_info = try allocator.dupeZ(u8, conn_info);

        const pg_copy_query = try std.fmt.allocPrintSentinel(
            allocator,
            \\ COPY (
            \\  {s}
            \\ ) TO STDOUT
            \\ WITH (
            \\  FORMAT CSV,
            \\  HEADER true,
            \\  DELIMITER '{s}'
            \\ );
        ,
            .{ source, col_sep },
            0,
        );

        return .{
            .pg_conn_info = pg_conn_info,
            .pg_copy_query = pg_copy_query,
            .file_path = sink,
        };
    }
};
