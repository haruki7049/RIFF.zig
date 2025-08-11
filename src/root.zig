const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Chunk = @import("./chunk.zig");
pub const RIFFChunk = @import("./riff_chunk.zig");
pub const ListChunk = @import("./list_chunk.zig");

/// A tool set to convert RIFFChunk and ListChunk to binary
pub const ToBinary = struct {
    /// Converts usize to [4]u8, in order to use in binary's size part
    pub fn size(value: usize) [4]u8 {
        return [4]u8{
            @intCast(value & 0xFF),
            @intCast((value >> 8) & 0xFF),
            @intCast((value >> 16) & 0xFF),
            @intCast((value >> 24) & 0xFF),
        };
    }

    /// Converts RIFFChunk or ListChunk to []u8, in order to use in binary's data part
    pub fn data(comptime T: type, self: T, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        const data_type: type = @FieldType(T, "data");

        if (data_type == []const RIFFChunk.Data) {
            for (self.data) |value| {
                const binary = switch (value) {
                    .chunk => try value.chunk.to_binary(allocator),
                    .list => try value.list.to_binary(allocator),
                };
                defer allocator.free(binary);

                try result.appendSlice(binary);
            }
        } else if (data_type == []const Chunk) {
            for (self.data) |chunk| {
                const binary = try chunk.to_binary(allocator);
                defer allocator.free(binary);

                try result.appendSlice(binary);
            }
        } else {
            unreachable;
        }

        return result.toOwnedSlice();
    }
};

/// A tool set to convert binary to RIFFChunk or ListChunk
pub const FromBinary = struct {
    pub fn size(value: [4]u8) usize {
        const first: u8 = value[0];
        const second: u8 = value[1] << 2;
        const third: u8 = value[2] << 4;
        const fourth: u8 = value[3] << 6;

        return first + second + third + fourth;
    }

    /// This function is used by RIFFChunk & ListChunk
    pub fn data(comptime T: type, input: []const u8, allocator: Allocator) !@FieldType(T, "data") {
        const data_type_info = @typeInfo(@FieldType(T, "data"));

        var result = ArrayList(data_type_info.pointer.child).init(allocator);
        defer result.deinit();

        if (input.len < 12)
            return result.toOwnedSlice();

        if (data_type_info.pointer.child == Chunk) {
            const chunks: []const Chunk = try FromBinary.to_chunks(input, allocator);
            defer allocator.free(chunks);

            try result.appendSlice(chunks);
        } else if (data_type_info.pointer.child == RIFFChunk.Data) {
            const d: []const RIFFChunk.Data = try FromBinary.to_data(input, allocator);
            defer allocator.free(d);

            try result.appendSlice(d);
        } else {
            unreachable;
        }

        return result.toOwnedSlice();
    }

    fn to_chunks(
        input: []const u8,
        allocator: Allocator,
    ) ![]const Chunk {
        var result = ArrayList(Chunk).init(allocator);

        const id_bin: [4]u8 = const_to_mut(input[0..4]);
        const size_bin: [4]u8 = const_to_mut(input[4..8]);
        const local_size: usize = FromBinary.size(size_bin);

        const four_cc_bin: [4]u8 = const_to_mut(input[8..12]);
        const data_len = local_size - 4;
        const data_bin: []const u8 = input[12 .. 12 + data_len];

        const chunk: Chunk = Chunk{
            .id = id_bin,
            .four_cc = four_cc_bin,
            .data = data_bin,
        };

        try result.append(chunk);

        return result.toOwnedSlice();
    }

    fn const_to_mut(slice: []const u8) [4]u8 {
        if (slice.len != 4) {
            std.debug.print("In FromBinary.const_to_mut()    slice: {any}", .{slice});
            std.debug.print("In FromBinary.const_to_mut()    slice.len: {d}", .{slice.len});
            @panic("slice length must be 4");
        }

        var result: [4]u8 = undefined;
        @memcpy(&result, slice);
        return result;
    }

    fn to_data(input: []const u8, allocator: Allocator) ![]const RIFFChunk.Data {
        var result = ArrayList(RIFFChunk.Data).init(allocator);

        const id_bin: [4]u8 = const_to_mut(input[0..4]);
        const size_bin: [4]u8 = const_to_mut(input[4..8]);
        const local_size: usize = FromBinary.size(size_bin);

        const four_cc_bin: [4]u8 = const_to_mut(input[8..12]);
        const data_len = local_size - 4;
        const data_bin: []const u8 = input[12 .. 12 + data_len];

        const d: RIFFChunk.Data = RIFFChunk.Data{ .chunk = Chunk{
            .id = id_bin,
            .four_cc = four_cc_bin,
            .data = data_bin,
        } };

        try result.append(d);

        return result.toOwnedSlice();
    }
};

test "minimal_list" {
    const list: ListChunk = ListChunk{
        .four_cc = .{ 'I', 'N', 'F', 'O' },
        .data = &.{},
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ 'W', 'A', 'V', 'E' },
        .data = &.{
            RIFFChunk.Data{ .list = list },
        },
    };

    try std.testing.expectEqual(riff.size(), 16);
}

test "minimal_riff" {
    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ 'W', 'A', 'V', 'E' },
        .data = &.{},
    };

    try std.testing.expectEqual(riff.size(), 4);
}

test "riff" {
    const data: Chunk = Chunk{
        .id = .{ 'd', 'a', 't', 'a' },
        .four_cc = .{ ' ', ' ', ' ', ' ' },
        .data = &.{},
    };
    const info: Chunk = Chunk{
        .id = .{ 'i', 'n', 'f', 'o' },
        .four_cc = .{ ' ', ' ', ' ', ' ' },
        .data = &.{},
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ 'W', 'A', 'V', 'E' },
        .data = &.{
            RIFFChunk.Data{ .chunk = data },
            RIFFChunk.Data{ .chunk = info },
        },
    };

    try std.testing.expectEqual(riff.size(), 28);
}

test "more_complex_riff" {
    const list: ListChunk = ListChunk{
        .four_cc = .{ 'I', 'N', 'F', 'O' },
        .data = &.{},
    };

    const data: Chunk = Chunk{
        .id = .{ 'd', 'a', 't', 'a' },
        .four_cc = .{ ' ', ' ', ' ', ' ' },
        .data = "EXAMPLE_DATA", // 12 bytes
    };

    const info: Chunk = Chunk{
        .id = .{ 'i', 'n', 'f', 'o' },
        .four_cc = .{ ' ', ' ', ' ', ' ' },
        .data = "THIS IS EXAMPLE DATA", // 20 bytes
    };

    const riff: RIFFChunk = RIFFChunk{
        .four_cc = .{ 'W', 'A', 'V', 'E' },
        .data = &.{
            RIFFChunk.Data{ .list = list },
            RIFFChunk.Data{ .chunk = data },
            RIFFChunk.Data{ .chunk = info },
        },
    };

    try std.testing.expectEqual(riff.size(), 72);
}
