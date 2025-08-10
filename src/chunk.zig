const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Self = @This();
const project_root = @import("./root.zig");
const ToBinary = project_root.ToBinary;

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

pub fn to_binary(self: Self, allocator: Allocator) ![]const u8 {
    const id_bin: []const u8 = self.id[0..];
    const size_bin: []const u8 = &ToBinary.size(self.size());
    const four_cc_bin: []const u8 = self.four_cc[0..];
    const data_bin: []const u8 = self.data;

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.appendSlice(id_bin);
    try result.appendSlice(size_bin);
    try result.appendSlice(four_cc_bin);
    try result.appendSlice(data_bin);

    return result.toOwnedSlice();
}

test "size" {
    const info_chunk: Self = Self{
        .id = .{ 'i', 'n', 'f', 'o' },
        .four_cc = .{ 'I', 'N', 'F', 'O' },
        .data = "THIS IS EXAMPLE DATA",
    };

    try testing.expectEqual(info_chunk.size(), 24);
}

test "to_binary" {
    const allocator = testing.allocator;
    const info_chunk: Self = Self{
        .id = .{ 'i', 'n', 'f', 'o' },
        .four_cc = .{ 'I', 'N', 'F', 'O' },
        .data = "THIS IS EXAMPLE DATA",
    };
    const info_chunk_data: []const u8 = try info_chunk.to_binary(allocator);
    defer allocator.free(info_chunk_data);

    testing.expect(std.mem.eql(u8, info_chunk_data, @embedFile("./riff_files/only_chunk/info.riff"))) catch {
        std.debug.print("info_chunk_data: {x}\n", .{info_chunk_data});
        return error.TestUnexpectedResult;
    };
}
