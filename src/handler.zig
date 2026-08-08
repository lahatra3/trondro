const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;
const PgCopyOut = @import("reader/copy.zig").PgCopyOut;

const QUEUE_DEPTH: u32 = 1024;

pub const Handler = struct {
    ring: linux.IoUring,
    file_offset: u64,
    pending_writes: u32,
    is_poll_armed: bool = false,

    slots: [QUEUE_DEPTH]Slot,
    free_slots_head: ?*Slot,
    poll_slot: Slot,

    pub const Tag = enum(u8) {
        socket_poll,
        file_write,
    };

    pub const Slot = struct {
        tag: Tag,
        index: u16,
        chunk: ?PgCopyOut.Chunk,
        next_free: ?*Slot,
    };

    pub fn init() !Handler {
        const ring = try linux.IoUring.init(QUEUE_DEPTH, 0);

        var self = Handler{
            .ring = ring,
            .file_offset = 0,
            .pending_writes = 0,
            .slots = undefined,
            .free_slots_head = null,
            .poll_slot = .{
                .tag = .socket_poll,
                .index = 0xFFFF,
                .chunk = null,
                .next_free = null,
            },
        };

        for (&self.slots, 0..) |*slot, i| {
            slot.* = .{
                .tag = .file_write,
                .index = @intCast(i),
                .chunk = null,
                .next_free = self.free_slots_head,
            };
            self.free_slots_head = slot;
        }

        return self;
    }

    pub fn deinit(self: *Handler) void {
        self.flushPendingWrites();
        assert(self.pending_writes == 0);
        self.ring.deinit();
    }

    pub fn handleStream(
        self: *Handler,
        copy_stream: *PgCopyOut,
        file_fd: posix.fd_t,
    ) !void {
        assert(file_fd >= 0);
        const pq_fd = copy_stream.getSocketFd();

        try self.armPoll(pq_fd);
        var copy_completed = false;
        var cqes_buf: [QUEUE_DEPTH]linux.io_uring_cqe = undefined;

        defer self.flushPendingWrites();

        while (!copy_completed or self.pending_writes > 0) {
            _ = try self.ring.submit_and_wait(1);

            const count = try self.ring.copy_cqes(
                &cqes_buf,
                0,
            );

            for (cqes_buf[0..count]) |cqe| {
                if (cqe.res < 0) {
                    std.log.err("io_uring Async I/O Error: {d}", .{cqe.res});
                    return error.IoUringOperationFailed;
                }

                const slot: *Slot = @ptrFromInt(cqe.user_data);

                switch (slot.tag) {
                    .socket_poll => {
                        self.is_poll_armed = false;
                        try copy_stream.consumeInput();
                        try self.drainCopy(
                            copy_stream,
                            file_fd,
                            pq_fd,
                            &copy_completed,
                        );
                    },
                    .file_write => {
                        assert(self.pending_writes > 0);
                        self.pending_writes -= 1;

                        if (slot.chunk) |chunk| {
                            chunk.deinit();
                            slot.chunk = null;
                        }

                        self.releaseSlot(slot);

                        if (!copy_completed) {
                            try self.drainCopy(
                                copy_stream,
                                file_fd,
                                pq_fd,
                                &copy_completed,
                            );
                        }
                    },
                }
            }
        }
    }

    fn drainCopy(
        self: *Handler,
        copy_stream: *PgCopyOut,
        file_fd: posix.fd_t,
        pq_fd: posix.fd_t,
        copy_completed: *bool,
    ) !void {
        while (self.free_slots_head != null) {
            switch (copy_stream.read()) {
                .chunk => |chunk| {
                    try self.submitWrite(file_fd, chunk);
                },
                .would_block => {
                    try self.armPoll(pq_fd);
                    break;
                },
                .done => {
                    copy_completed.* = true;
                    break;
                },
                .err => |msg| {
                    std.log.err("Postgres copy error: {s}", .{msg});
                    return error.PostgresCopyStreamError;
                },
            }
        }
    }

    fn armPoll(
        self: *Handler,
        fd: posix.fd_t,
    ) !void {
        if (self.is_poll_armed) return;
        const sqe = try self.ring.get_sqe();
        sqe.prep_poll_add(fd, linux.POLL.IN);
        sqe.user_data = @intFromPtr(&self.poll_slot);
        self.is_poll_armed = true;
    }

    fn submitWrite(
        self: *Handler,
        file_fd: posix.fd_t,
        chunk: PgCopyOut.Chunk,
    ) !void {
        const slot = self.acquireSlot() orelse {
            return error.OutOfWriteSlots;
        };
        slot.tag = .file_write;
        slot.chunk = chunk;

        const sqe = try self.ring.get_sqe();
        sqe.prep_write(
            file_fd,
            chunk.slice(),
            self.file_offset,
        );
        sqe.user_data = @intFromPtr(slot);

        self.file_offset += chunk.len;
        self.pending_writes += 1;
    }

    fn acquireSlot(self: *Handler) ?*Slot {
        const slot = self.free_slots_head orelse {
            return null;
        };
        self.free_slots_head = slot.next_free;
        slot.next_free = null;
        return slot;
    }

    fn releaseSlot(
        self: *Handler,
        slot: *Slot,
    ) void {
        slot.next_free = self.free_slots_head;
        self.free_slots_head = slot;
    }

    fn flushPendingWrites(self: *Handler) void {
        var cqes_buf: [QUEUE_DEPTH]linux.io_uring_cqe = undefined;

        while (self.pending_writes > 0) {
            _ = self.ring.submit_and_wait(1) catch break;
            const count = self.ring.copy_cqes(
                &cqes_buf,
                0,
            ) catch {
                break;
            };
            for (cqes_buf[0..count]) |cqe| {
                const slot: *Slot = @ptrFromInt(cqe.user_data);
                if (slot.tag == .file_write) {
                    if (self.pending_writes > 0) {
                        self.pending_writes -= 1;
                    }
                    if (slot.chunk) |chunk| {
                        chunk.deinit();
                        slot.chunk = null;
                    }
                    self.releaseSlot(slot);
                }
            }
        }
    }
};
