const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("./chunk.zig");
const Self = @This();

const project_root = @import("./root.zig");
const ToBinary = project_root.ToBinary;

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

pub fn to_binary(self: Self, allocator: Allocator) ![]u8 {
    const id_bin: []const u8 = self.id[0..];
    const size_bin: [4]u8 = ToBinary.size(self.size());
    const four_cc_bin: []const u8 = self.four_cc[0..];
    const data_bin: []const u8 = try ToBinary.data(Self, self, allocator);
    defer allocator.free(data_bin);

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.appendSlice(id_bin);
    try result.appendSlice(&size_bin);
    try result.appendSlice(four_cc_bin);
    try result.appendSlice(data_bin);

    return result.toOwnedSlice();
}
