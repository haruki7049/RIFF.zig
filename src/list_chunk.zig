const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("./chunk.zig");
const Self = @This();

id: [4]u8 = .{ 'L', 'I', 'S', 'T' },
four_cc: [4]u8,
data: []const Chunk,

/// Calculate this list's data size
/// This function uses Byte
pub fn size(self: Self) usize {
    const four_cc_size = self.four_cc.len;
    const data_size: usize = blk: {
        var result: usize = 0;

        for (self.data) |chunk| {
            result += 4; // Chunk's ID
            result += 4; // Chunk's Size
            result += chunk.size();
        }

        break :blk result;
    };

    return four_cc_size + data_size;
}

fn convert_size(value: usize) [4]u8 {
    return [4]u8{
        @intCast(value & 0xFF),
        @intCast((value >> 8) & 0xFF),
        @intCast((value >> 16) & 0xFF),
        @intCast((value >> 24) & 0xFF),
    };
}

fn to_binary(self: Self, allocator: Allocator) ![]u8 {
    const id_bin: []const u8 = self.id[0..];
    const size_bin: [4]u8 = self.convert_size(self.size());
    const four_cc_bin: []const u8 = self.four_cc[0..];
    const data_bin: []const u8 = try convert_chunks(self.data[0..], allocator);
    defer allocator.free(data_bin);

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.appendSlice(id_bin);
    try result.appendSlice(&size_bin);
    try result.appendSlice(four_cc_bin);
    try result.appendSlice(data_bin);

    return result.toOwnedSlice();
}

fn convert_chunks(chunks: []const Chunk, allocator: Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (chunks) |chunk| {
        const binary = try chunk.to_binary(allocator);
        try result.appendSlice(binary);
        allocator.free(binary);
    }

    return result.toOwnedSlice();
}
