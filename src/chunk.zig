const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Self = @This();
const project_root = @import("./root.zig");
const ToBinary = project_root.ToBinary;
const FromBinary = project_root.FromBinary;

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

    var result: std.array_list.Aligned(u8, null) = .empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, id_bin);
    try result.appendSlice(allocator, size_bin);
    try result.appendSlice(allocator, four_cc_bin);
    try result.appendSlice(allocator, data_bin);

    return result.toOwnedSlice(allocator);
}

pub fn from_binary(input: []const u8) Self {
    const id: [4]u8 = input[0..4].*;
    const size_bin: [4]u8 = input[4..8].*;
    const four_cc: [4]u8 = input[8..12].*;
    const data: []const u8 = input[12..];

    const result: Self = Self{
        .id = id,
        .four_cc = four_cc,
        .data = data,
    };

    std.debug.assert(result.size() == FromBinary.size(size_bin));

    return result;
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

    const test_data: []const u8 = @embedFile("./riff_files/only_chunk/info.riff");

    testing.expect(std.mem.eql(u8, info_chunk_data, test_data)) catch {
        std.debug.print("info_chunk_data: {x}\n", .{info_chunk_data});
        std.debug.print("test_data: {x}\n", .{test_data});
        return error.TestUnexpectedResult;
    };
}

test "from_binary" {
    const info_chunk_data: []const u8 = @embedFile("./riff_files/only_chunk/info.riff");
    const result: Self = Self.from_binary(info_chunk_data);

    try testing.expect(std.mem.eql(u8, &result.id, &[_]u8{ 'i', 'n', 'f', 'o' }));
    try testing.expectEqual(result.size(), 24);
    try testing.expect(std.mem.eql(u8, &result.four_cc, &[_]u8{ 'I', 'N', 'F', 'O' }));
    try testing.expect(std.mem.eql(u8, result.data, "THIS IS EXAMPLE DATA"));
}
