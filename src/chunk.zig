const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();

id: [4]u8,
four_cc: [4]u8,
data: []const u8,

/// Calculate this chunk's data size
/// This function uses Byte
pub fn size(self: Self) usize {
    const four_cc_size: usize = self.four_cc.len;
    const data_size: usize = self.data.len;

    return four_cc_size + data_size;
}

pub fn to_binary(self: Self, allocator: Allocator) ![]u8 {
    const id_bin: []const u8 = self.id[0..];
    const size_bin = convert_size(self.size());
    const four_cc_bin: []const u8 = self.four_cc[0..];
    const data_bin: []const u8 = self.data;

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.appendSlice(id_bin);
    try result.appendSlice(&size_bin);
    try result.appendSlice(four_cc_bin);
    try result.appendSlice(data_bin);

    return result.toOwnedSlice();
}

fn convert_size(value: usize) [4]u8 {
    return [4]u8{
        @intCast(value & 0xFF),
        @intCast((value >> 8) & 0xFF),
        @intCast((value >> 16) & 0xFF),
        @intCast((value >> 24) & 0xFF),
    };
}
