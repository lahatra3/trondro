const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const posix = std.posix;
const PgCopyOut = @import("postgres/copy.zig").PgCopyOut;

const QUEUE_DEPTH: u32 = 128;

pub const Handler = struct {
    ring: linux.IoUring,
    file_offset: u64,
    pending_writes: u32,

    slots: [QUEUE_DEPTH]Slot,
    free_slots_head: ?*Slot,

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

        var poll_slot = Slot{
            .tag = .socket_poll,
            .index = 0xFFFF,
            .chunk = null,
            .next_free = null,
        };

        try self.armPoll(pq_fd, &poll_slot);
        var copy_completed = false;
        var cqes_buf: [QUEUE_DEPTH]linux.io_uring_cqe = undefined;

        while (!copy_completed or self.pending_writes > 0) {
            const completions = try self.ring.submit_and_wait(1);
            assert(completions > 0);

            const count = try self.ring.copy_cqes(
                &cqes_buf,
                0,
            );

            for (cqes_buf[0..count]) |cqe| {
                assert(cqe.res > 0);
                const slot: *Slot = @ptrFromInt(cqe.user_data);

                switch (slot.tag) {
                    .socket_poll => {
                        try copy_stream.consumeInput();

                        var iteration: u32 = 0;
                        const max_iterations_per_event: u32 = 1_000;

                        while (iteration < max_iterations_per_event) : (iteration += 1) {
                            switch (copy_stream.read()) {
                                .chunk => |chunk| {
                                    try self.submitWrite(
                                        file_fd,
                                        chunk,
                                    );
                                },
                                .would_block => {
                                    try self.armPoll(pq_fd, &poll_slot);
                                    break;
                                },
                                .done => {
                                    copy_completed = true;
                                    break;
                                },
                                .err => |e| {
                                    std.log.err("Error: {s}", .{e});
                                    return error.PostgresCopyStreamError;
                                },
                            }
                        }
                    },
                    .file_write => {
                        assert(self.pending_writes > 0);
                        self.pending_writes -= 1;

                        if (slot.chunk) |chunk| {
                            chunk.deinit();
                            slot.chunk = null;
                        }

                        self.releaseSlot(slot);
                    },
                }
            }
        }
    }

    fn armPoll(
        self: *Handler,
        fd: posix.fd_t,
        slot: *Slot,
    ) !void {
        assert(slot.tag == .socket_poll);
        const sqe = try self.ring.get_sqe();
        sqe.prep_poll_add(fd, linux.POLL.IN);
        sqe.user_data = @intFromPtr(slot);
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
};
