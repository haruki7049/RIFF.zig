const std = @import("std");
const riff_zig = @import("riff_zig");
const RIFFChunk = riff_zig.RIFFChunk;

const riff_chunk: RIFFChunk = RIFFChunk{
    .four_cc = .{ &'W', &'A', &'V', &'E' },
    .data = &.{},
};

pub fn main() !void {
    const file = try std.fs.cwd().createFile(
        "simple.riff",
        .{ .read = true },
    );
    defer file.close();

    try file.writeAll(riff_chunk.to_binary());
}
