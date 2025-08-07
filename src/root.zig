const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Chunk = @import("./chunk.zig");
pub const RIFFChunk = @import("./riff_chunk.zig");
pub const ListChunk = @import("./list_chunk.zig");

pub const ToBinary = struct {
    pub fn size(value: usize) [4]u8 {
        return [4]u8{
            @intCast(value & 0xFF),
            @intCast((value >> 8) & 0xFF),
            @intCast((value >> 16) & 0xFF),
            @intCast((value >> 24) & 0xFF),
        };
    }

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

                try result.appendSlice(binary);
                allocator.free(binary);
            }
        } else if (data_type == []const Chunk) {

            for (self.data) |chunk| {
                const binary = try chunk.to_binary(allocator);
                try result.appendSlice(binary);
                allocator.free(binary);
            }
        }

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
