const std = @import("std");
const testing = std.testing;
const Self = @This();
const Chunk = @import("./chunk.zig");
const ListChunk = @import("./list_chunk.zig");

const project_root = @import("./root.zig");
const ToBinary = project_root.ToBinary;
const FromBinary = project_root.FromBinary;

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

pub fn to_binary(
    self: Self,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const id_bin: []const u8 = self.id[0..];
    const size_bin: []const u8 = &ToBinary.size(self.size());
    const four_cc_bin: []const u8 = self.four_cc[0..];
    const data_bin: []const u8 = try ToBinary.data(Self, self, allocator);
    defer allocator.free(data_bin);

    var result: std.array_list.Aligned(u8, null) = .empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, id_bin);
    try result.appendSlice(allocator, size_bin);
    try result.appendSlice(allocator, four_cc_bin);
    try result.appendSlice(allocator, data_bin);

    return result.toOwnedSlice(allocator);
}

pub fn from_binary(input: []const u8, allocator: std.mem.Allocator) !Self {
    const id_bin: [4]u8 = input[0..4].*;
    // const size_bin: [4]u8 = input[4..8].*;
    const four_cc_bin: [4]u8 = input[8..12].*;
    const data: []const Data = try FromBinary.data(Self, input[12..], allocator);

    const result: Self = Self{
        .four_cc = four_cc_bin,
        .data = data,
    };

    // std.debug.print("id_bin: {s}\n", .{id_bin});
    // std.debug.print("size_bin: {any}\n", .{size_bin});
    // std.debug.print("FromBinary.size(size_bin): {any}\n", .{FromBinary.size(size_bin)});
    // std.debug.print("result.size(): {any}\n", .{result.size()});

    std.debug.assert(std.mem.eql(u8, &id_bin, &[_]u8{ 'R', 'I', 'F', 'F' }));
    // std.debug.assert(result.size() == FromBinary.size(size_bin));

    return result;
}

pub const Data = union(enum) {
    chunk: Chunk,
    list: ListChunk,
};

test "size" {
    const only_riff_chunk: Self = Self{
        .four_cc = .{ 'D', 'A', 'T', 'A' },
        .data = &[_]Data{},
    };

    try testing.expectEqual(only_riff_chunk.size(), 4);
}

test "to_binary" {
    const allocator = testing.allocator;
    const only_riff: Self = Self{
        .four_cc = .{ 'D', 'A', 'T', 'A' },
        .data = &[_]Data{},
    };
    const only_riff_data: []const u8 = try only_riff.to_binary(allocator);
    defer allocator.free(only_riff_data);

    const test_data: []const u8 = @embedFile("./riff_files/only_riff_chunk/only_riff.riff");

    testing.expect(std.mem.eql(u8, only_riff_data, test_data)) catch {
        std.debug.print("only_riff_data: {x}\n", .{only_riff_data});
        std.debug.print("test_data: {x}\n", .{test_data});
        return error.TestUnexpectedResult;
    };
}

test "from_binary only_riff_chunk" {
    const allocator = testing.allocator;
    const only_riff_data: []const u8 = @embedFile("./riff_files/only_riff_chunk/only_riff.riff");
    const only_riff_result: Self = try Self.from_binary(only_riff_data, allocator);
    defer allocator.free(only_riff_result.data);

    try testing.expect(std.mem.eql(u8, &only_riff_result.id, &[_]u8{ 'R', 'I', 'F', 'F' }));
    try testing.expectEqual(only_riff_result.size(), 4);
    try testing.expect(std.mem.eql(u8, &only_riff_result.four_cc, &[_]u8{ 'D', 'A', 'T', 'A' }));
    try testing.expectEqual(only_riff_result.data, &[_]Self.Data{});
}
