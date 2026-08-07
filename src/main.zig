const std = @import("std");
const PgClient = @import("postgres/client.zig").PgClient;
const Handler = @import("handler.zig").Handler;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const pg_conn_info = "host=172.17.0.1 port=5431 dbname=dvdrental user=postgres password=p0stgr3s";
    var pg_client = try PgClient.init(pg_conn_info);
    defer pg_client.deinit();

    const file_path = "/home/jhs/Projects/zig/lahatra3/trondro.csv";
    const sink_file = try std.Io.Dir.createFileAbsolute(
        io,
        file_path,
        .{},
    );
    defer sink_file.close(io);

    const source_query =
        \\ COPY (
        \\  SELECT * FROM public.rental
        \\ ) TO STDOUT
        \\ WITH (
        \\  FORMAT CSV,
        \\  HEADER true,
        \\  DELIMITER '|'
        \\ );
    ;
    var copy_stream = try pg_client.startAsyncCopyOut(source_query);

    var handler = try Handler.init();
    defer handler.deinit();

    std.log.info("Processing...", .{});
    try handler.handleStream(
        &copy_stream,
        sink_file.handle,
    );
    std.log.info("Successfully completed...", .{});
}
