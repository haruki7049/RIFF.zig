const std = @import("std");
const riff_zig = @import("riff_zig");
const RIFFChunk = riff_zig.RIFFChunk;

const riff_chunk: RIFFChunk = RIFFChunk{
    .four_cc = .{ 'W', 'A', 'V', 'E' },
    .data = &[_]RIFFChunk.Data{},
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(general_purpose_allocator.deinit() == .ok);

    const gpa = general_purpose_allocator.allocator();
    const bin: []const u8 = try riff_chunk.to_binary(gpa);
    defer gpa.free(bin);

    // std.debug.print("{any}\n", .{bin});

    const file = try std.fs.cwd().createFile(
        "simple.riff",
        .{ .read = true },
    );
    defer file.close();

    try file.writeAll(bin);
}
