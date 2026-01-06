const std = @import("std");

/// Represents a RIFF (Resource Interchange File Format) chunk.
/// models the three types of chunks that can appear in RIFF files.
pub const Chunk = union(enum) {
    /// A basic RIFF chunk with a FourCC identifier and data payload.
    /// The `four_cc` is a 4-byte identifier (e.g., "fmt ", "data").
    chunk: struct {
        four_cc: [4]u8,
        data: []const u8,
    },
    /// A LIST chunk containing a list of sub-chunks.
    list: []const Chunk,
    /// A RIFF chunk representing the root container of a RIFF file.
    /// The `four_cc` specifies the file type (e.g., "WAVE").
    riff: struct {
        four_cc: [4]u8,
        chunks: []const Chunk,
    },

    /// Deallocates memory if chunks were dynamically allocated.
    pub fn deinit(self: Chunk, allocator: std.mem.Allocator) void {
        switch (self) {
            .basic => |b| allocator.free(b.data),
            .list => |l| {
                for (l) |child| child.deinit(allocator);
                allocator.free(l);
            },
            .riff => |r| {
                for (r.chunks) |child| child.deinit(allocator);
                allocator.free(r.chunks);
            },
        }
    }
};

pub const Error = error{
    InvalidFormat,
    InvalidId,
    InvalidSize,
    InvalidData,
    SizeMismatch,
    OutOfMemory,
};

/// Converts a RIFF chunk to its binary representation.
/// Serialization follows: Header (4 bytes) + Size (4 bytes, LE) + Data.
pub fn to_writer(chunk: Chunk, allocator: std.mem.Allocator, writer: anytype) !void {
    switch (chunk) {
        .chunk => |b| {
            try writer.writeAll(&b.four_cc);
            try writer.writeInt(u32, @intCast(b.data.len), .little);
            try writer.writeAll(b.data);
        },
        .list => |l| {
            var buf: std.array_list.Aligned(u8, null) = .empty;
            defer buf.deinit(allocator);
            for (l) |child| try to_writer(child, allocator, buf.writer(allocator));

            try writer.writeAll("LIST");
            try writer.writeInt(u32, @intCast(buf.items.len), .little);
            try writer.writeAll(buf.items);
        },
        .riff => |r| {
            var buf: std.array_list.Aligned(u8, null) = .empty;
            defer buf.deinit(allocator);
            for (r.chunks) |child| try to_writer(child, allocator, buf.writer(allocator));

            try writer.writeAll("RIFF");
            try writer.writeInt(u32, @intCast(buf.items.len + 4), .little);
            try writer.writeAll(&r.four_cc);
            try writer.writeAll(buf.items);
        },
    }
}

/// Parses a RIFF chunk from binary data.
pub fn from_slice(allocator: std.mem.Allocator, bytes: []const u8) Error!Chunk {
    if (bytes.len < 8) return error.InvalidFormat;

    const id = bytes[0..4];
    const size = std.mem.readInt(u32, bytes[4..8], .little);

    if (std.mem.eql(u8, id, "RIFF")) {
        if (bytes.len < 12) return error.InvalidFormat;
        const four_cc = bytes[8..12];
        const chunks = try to_chunk_list(allocator, bytes[12..]);
        return Chunk{ .riff = .{ .four_cc = four_cc.*, .chunks = chunks } };
    } else if (std.mem.eql(u8, id, "LIST")) {
        const chunks = try to_chunk_list(allocator, bytes[8..]);
        return Chunk{ .list = chunks };
    } else {
        const data_end = 8 + size;
        if (bytes.len < data_end) return error.SizeMismatch;
        const data = try allocator.dupe(u8, bytes[8..data_end]);
        return Chunk{ .chunk = .{ .four_cc = id.*, .data = data } };
    }
}

fn to_chunk_list(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)![]const Chunk {
    var list: std.array_list.Aligned(Chunk, null) = .empty;
    errdefer {
        for (list.items) |c| c.deinit(allocator);
        list.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < bytes.len) {
        if (pos + 8 > bytes.len) return error.InvalidFormat;
        const id = bytes[pos .. pos + 4];
        const size = std.mem.readInt(u32, bytes[pos + 4 .. pos + 8], .little);
        const next_pos = pos + 8 + size;

        if (next_pos > bytes.len) return error.SizeMismatch;

        const chunk_data = try allocator.dupe(u8, bytes[pos + 8 .. next_pos]);
        try list.append(Chunk{ .basic = .{ .four_cc = id.*, .data = chunk_data } });

        pos = next_pos;
    }

    return list.toOwnedSlice(allocator);
}

test "Wave" {
    _ = Chunk{
        .riff = .{
            .four_cc = "WAVE".*,
            .chunks = &[_]Chunk{
                .{ .chunk = .{ .four_cc = "fmt ".*, .data = "" } },
                .{ .chunk = .{ .four_cc = "data".*, .data = "" } },
            },
        },
    };
}

test "chunk serialization" {
    const allocator = std.testing.allocator;

    const chunk = Chunk{ .chunk = .{
        .four_cc = "fmt ".*,
        .data = "EXAMPLE_DATA",
    } };

    var list: std.array_list.Aligned(u8, null) = blk: {
        var list: std.array_list.Aligned(u8, null) = .empty;
        errdefer list.deinit(allocator);

        try to_writer(chunk, allocator, list.writer(allocator));
        break :blk list;
    };
    defer list.deinit(allocator);

    const expected = "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "list_chunk serialization" {
    const allocator = std.testing.allocator;

    const list_chunk = Chunk{ .list = &.{
        .{ .chunk = .{ .four_cc = "fmt ".*, .data = "EXAMPLE_DATA" } },
        .{ .chunk = .{ .four_cc = "fmt ".*, .data = "EXAMPLE_DATA" } },
    } };

    var list: std.array_list.Aligned(u8, null) = blk: {
        var list: std.array_list.Aligned(u8, null) = .empty;
        errdefer list.deinit(allocator);

        try to_writer(list_chunk, allocator, list.writer(allocator));
        break :blk list;
    };
    defer list.deinit(allocator);

    const expected = "LIST" ++ "\x28\x00\x00\x00" ++ "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA" ++ "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}
