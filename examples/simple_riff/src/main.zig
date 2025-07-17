const std = @import("std");
const riff_zig = @import("riff_zig");
const RIFFChunk = riff_zig.RIFFChunk;

const riff_chunk: RIFFChunk = RIFFChunk{
    .four_cc = .{ &'W', &'A', &'V', &'E' },
    .data = &.{},
};

pub fn main() void {
    std.debug.print("riff_size: {d}\n", .{riff_chunk.size()});
}
