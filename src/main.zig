const std = @import("std");
const assert = std.debug.assert;
const PgClient = @import("reader/client.zig").PgClient;
const FileWriter = @import("writer/file_writer.zig").FileWriter;
const Handler = @import("handler.zig").Handler;
const Config = @import("config.zig").Config;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const env_map = init.environ_map;

    const config = try Config.load(allocator, env_map);

    assert(config.pg_conn_info.len > 0);
    var pg_client = try PgClient.init(config.pg_conn_info);
    defer pg_client.deinit();

    assert(config.file_path.len > 0);
    var writer = try FileWriter.init(io, config.file_path);
    defer writer.deinit();

    assert(config.pg_copy_query.len > 0);
    var reader = try pg_client.startAsyncCopyOut(config.pg_copy_query);

    var handler = try Handler.init();
    defer handler.deinit();

    std.log.info("[Trondro]: Start processing...", .{});
    try handler.handleStream(
        &reader,
        writer.handle,
    );
    try writer.sync();

    std.log.info("[Trondro]: Processing completed successfully...", .{});
}
