const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();
const Chunk = @import("./chunk.zig");
const ListChunk = @import("./list_chunk.zig");

id: [4]u8 = .{ 'R', 'I', 'F', 'F' },
four_cc: [4]u8,
data: []const Data,

/// Calculate this RIFFChunk's data size
/// This function uses Byte
pub fn size(self: Self) usize {
    const four_cc_size = self.four_cc.len;
    var data_size: usize = 0;

    for (self.data) |data| {
        switch (data) {
            .chunk => {
                data_size += data.chunk.id.len; // Chunk ID length
                data_size += 4; // Length of the Chunk size itself
                data_size += data.chunk.size(); // Chunk's size
            },
            .list => {
                data_size += data.list.id.len; // List's id length
                data_size += 4; // Length of the List size itself
                data_size += data.list.size(); // List's size
            },
        }
    }

    return data_size + four_cc_size;
}

fn convert_size(_: Self, value: usize) [4]u8 {
    return [4]u8{
        @intCast(value & 0xFF),
        @intCast((value >> 8) & 0xFF),
        @intCast((value >> 16) & 0xFF),
        @intCast((value >> 24) & 0xFF),
    };
}

fn convert_data(_: Self, values: []const Self.Data, allocator: Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (values) |value| {
        const binary = switch (value) {
            .chunk => try value.chunk.to_binary(allocator),
            .list => try value.list.to_binary(allocator),
        };

        try result.appendSlice(binary);
        allocator.free(binary);
    }

    return result.toOwnedSlice();
}

pub fn to_binary(
    self: Self,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const id_bin: []const u8 = self.id[0..];
    const size_bin: []const u8 = &self.convert_size(self.size());
    const four_cc_bin: []const u8 = self.four_cc[0..];
    const data_bin: []const u8 = try self.convert_data(self.data, allocator);
    defer allocator.free(data_bin);

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.appendSlice(id_bin);
    try result.appendSlice(size_bin);
    try result.appendSlice(four_cc_bin);
    try result.appendSlice(data_bin);

    return result.toOwnedSlice();
}

pub const Data = union(DataTag) {
    chunk: Chunk,
    list: ListChunk,
};

pub const DataTag = enum {
    chunk,
    list,
};
