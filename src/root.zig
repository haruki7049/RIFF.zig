const std = @import("std");

const RIFFHeader = struct {
    id: [4]u8 = .{ 'R', 'I', 'F', 'F' },
    file_size: u32,
    format: [4]u8,

    pub fn write(self: *const RIFFHeader, writer: anytype) !void {
        const file_size: []u8 = undefined;
        std.mem.writeInt([]const u8, file_size, self.file_size, .little);

        try writer.writeAll(&self.id);
        try writer.writeAll(file_size);
        try writer.writeAll(&self.format);
    }
};

const Chunk = struct {
    id: [4]u8,
    size: u32,
    data: []const u8,

    pub fn write(self: *const Chunk, writer: anytype) !void {
        try writer.writeAll(&self.id);
        try writer.writeIntLittle(u32, self.size);
        try writer.writeAll(self.data);
    }
};

const ListChunk = struct {
    id: [4]u8 = .{ 'L', 'I', 'S', 'T' },
    size: u32,
    list_type: [4]u8,
    sub_chunks: []const Chunk,
    sub_lists: []const ListChunk, // Support nested LIST chunks

    pub fn write(self: *const ListChunk, writer: anytype) !void {
        try writer.writeAll(&self.id);
        try writer.writeIntLittle(u32, self.size);
        try writer.writeAll(&self.list_type);

        for (self.sub_chunks) |chunk| {
            try chunk.write(writer);
        }

        for (self.sub_lists) |list| {
            try list.write(writer);
        }
    }
};

test "Test" {
    const file = try std.fs.cwd().createFile("nested_riff.riff", .{});
    defer file.close();
    const writer = file.writer();

    // RIFF Header
    const riff_header = RIFFHeader{
        .file_size = 4 + 8 + 4, // Placeholder size
        .format = .{ 'W', 'A', 'V', 'E' },
    };
    try riff_header.write(writer);

    // Sub-chunks inside LIST
    const sub_chunk_1 = Chunk{
        .id = .{ 'I', 'N', 'F', 'O' },
        .size = 4,
        .data = "Test",
    };

    // Nested LIST chunk (inside another LIST)
    const nested_list = ListChunk{
        .size = 4 + 8 + sub_chunk_1.size, // LIST type + sub-chunk
        .list_type = .{ 'D', 'A', 'T', 'A' },
        .sub_chunks = &[_]Chunk{sub_chunk_1},
        .sub_lists = &[_]ListChunk{}, // No deeper nesting here
    };

    // Main LIST chunk (contains nested LIST)
    const main_list = ListChunk{
        .size = 4 + 8 + nested_list.size,
        .list_type = .{ 'I', 'N', 'F', 'O' },
        .sub_chunks = &[_]Chunk{},
        .sub_lists = &[_]ListChunk{nested_list},
    };

    try main_list.write(writer);

    std.debug.print("Nested RIFF file created!\n", .{});
}
