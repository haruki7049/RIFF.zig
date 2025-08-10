const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Chunk = @import("./chunk.zig");
const Self = @This();

const project_root = @import("./root.zig");
const ToBinary = project_root.ToBinary;
const FromBinary = project_root.FromBinary;

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

pub fn from_binary(input: []const u8, allocator: Allocator) !Self {
    const id: [4]u8 = input[0..4].*;
    const size_bin: [4]u8 = input[4..8].*;
    const four_cc: [4]u8 = input[8..12].*;
    const data: []const Chunk = try FromBinary.data(Chunk, input[12..], allocator);

    const result: Self = Self{
        .four_cc = four_cc,
        .data = data,
    };

    std.debug.assert(std.mem.eql(u8, &id, &[_]u8{ 'L', 'I', 'S', 'T' }));
    std.debug.assert(result.size() == FromBinary.size(size_bin));

    return result;
}

test "size" {
    const list_chunk: Self = Self{
        .four_cc = .{ 'I', 'N', 'F', 'O' },
        .data = &[_]Chunk{},
    };

    try testing.expectEqual(list_chunk.size(), 4);
}

test "to_binary" {
    const allocator = testing.allocator;
    const list_chunk: Self = Self{
        .four_cc = .{ 'I', 'N', 'F', 'O' },
        .data = &[_]Chunk{},
    };
    const data: []const u8 = try list_chunk.to_binary(allocator);
    defer allocator.free(data);

    testing.expect(std.mem.eql(u8, data, @embedFile("./riff_files/only_list_chunk/only_list.riff"))) catch {
        std.debug.print("data: {x}\n", .{data});
        return error.TestUnexpectedResult;
    };
}

test "from_binary list_with_info" {
    const allocator = testing.allocator;
    const list_with_info_data: []const u8 = @embedFile("./riff_files/list_chunk/list_with_info.riff");
    const list_with_info_result: Self = try Self.from_binary(list_with_info_data, allocator);
    defer allocator.free(list_with_info_result.data);

    try testing.expect(std.mem.eql(u8, &list_with_info_result.id, &[_]u8{ 'L', 'I', 'S', 'T' }));
    try testing.expectEqual(list_with_info_result.size(), 16);
    try testing.expect(std.mem.eql(u8, &list_with_info_result.four_cc, &[_]u8{ 'I', 'N', 'F', 'O' }));

    try testing.expect(std.mem.eql(u8, &list_with_info_result.data[0].id, &[_]u8{ 'i', 'n', 'f', 'o' }));
    try testing.expectEqual(list_with_info_result.data[0].size(), 4);
    try testing.expectEqualStrings(&list_with_info_result.data[0].four_cc, &[_]u8{ 'f', 'm', 't', ' ' });
    try testing.expectEqualStrings(list_with_info_result.data[0].data, "");
}

test "from_binary list_with_data" {
    const allocator = testing.allocator;
    const list_with_info_data: []const u8 = @embedFile("./riff_files/list_chunk/list_with_data.riff");
    const list_with_info_result: Self = try Self.from_binary(list_with_info_data, allocator);
    defer allocator.free(list_with_info_result.data);

    try testing.expect(std.mem.eql(u8, &list_with_info_result.id, &[_]u8{ 'L', 'I', 'S', 'T' }));
    try testing.expectEqual(list_with_info_result.size(), 16);
    try testing.expect(std.mem.eql(u8, &list_with_info_result.four_cc, &[_]u8{ 'I', 'N', 'F', 'O' }));

    try testing.expect(std.mem.eql(u8, &list_with_info_result.data[0].id, &[_]u8{ 'd', 'a', 't', 'a' }));
    try testing.expectEqual(list_with_info_result.data[0].size(), 4);
    try testing.expectEqualStrings(&list_with_info_result.data[0].four_cc, &[_]u8{ 'f', 'm', 't', ' ' });
    try testing.expectEqualStrings(list_with_info_result.data[0].data, "");
}

test "from_binary only_list_chunk" {
    const allocator = testing.allocator;
    const only_list_chunk_data: []const u8 = @embedFile("./riff_files/only_list_chunk/only_list.riff");
    const only_list_chunk_result: Self = try Self.from_binary(only_list_chunk_data, allocator);
    defer allocator.free(only_list_chunk_result.data);

    try testing.expect(std.mem.eql(u8, &only_list_chunk_result.id, &[_]u8{ 'L', 'I', 'S', 'T' }));
    try testing.expectEqual(only_list_chunk_result.size(), 4);
    try testing.expect(std.mem.eql(u8, &only_list_chunk_result.four_cc, &[_]u8{ 'I', 'N', 'F', 'O' }));
    try testing.expectEqual(only_list_chunk_result.data, &[_]Chunk{});
}
