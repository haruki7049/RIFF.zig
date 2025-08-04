const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Chunk = @import("./chunk.zig");
pub const RIFFChunk = @import("./riff_chunk.zig");
pub const ListChunk = @import("./list_chunk.zig");

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
