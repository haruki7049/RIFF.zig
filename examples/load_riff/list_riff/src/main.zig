const std = @import("std");
const riff_zig = @import("riff_zig");
const RIFFChunk = riff_zig.RIFFChunk;
const ListChunk = riff_zig.ListChunk;
const Chunk = riff_zig.Chunk;

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(general_purpose_allocator.deinit() == .ok);
    const gpa = general_purpose_allocator.allocator();

    const data: []const u8 = @embedFile("./assets/list.riff");
    const riff_chunk: RIFFChunk = try RIFFChunk.from_binary(data, gpa);
    defer gpa.free(riff_chunk.data);

    std.debug.print("list.riff: {any}\n", .{riff_chunk});
}
