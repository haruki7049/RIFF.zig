const std = @import("std");
const riff_zig = @import("riff_zig");
const RIFFChunk = riff_zig.RIFFChunk;
const ListChunk = riff_zig.ListChunk;
const Chunk = riff_zig.Chunk;

const data: Chunk = Chunk{
    .id = .{ 'd', 'a', 't', 'a' },
    .four_cc = .{ ' ', ' ', ' ', ' ' },
    .data = "EXAMPLE_DATA", // 12 bytes
};

const list: ListChunk = ListChunk{
    .four_cc = .{ 'I', 'N', 'F', 'O' },
    .data = &[_]Chunk{
        data,
    },
};

const riff_chunk: RIFFChunk = RIFFChunk{
    .four_cc = .{ 'W', 'A', 'V', 'E' },
    .data = &[_]RIFFChunk.Data{
        .{ .list = list },
    },
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(general_purpose_allocator.deinit() == .ok);

    const gpa = general_purpose_allocator.allocator();
    const bin: []const u8 = try riff_chunk.to_binary(gpa);
    defer gpa.free(bin);

    // std.debug.print("{*}\n", .{bin});

    const file = try std.fs.cwd().createFile(
        "list.riff",
        .{ .read = true },
    );
    defer file.close();

    try file.writeAll(bin);
}
