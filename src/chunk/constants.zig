const id = @import("./id.zig");

pub const RiffID: id.ChunkID = id.ChunkID.init(.{
    .value = [4]u8{ 'R', 'I', 'F', 'F' },
});

pub const ListID: id.ChunkID = id.ChunkID.init(.{
    .value = [4]u8{ 'L', 'I', 'S', 'T' },
});

pub const SeqtID: id.ChunkID = id.ChunkID.init(.{
    .value = [4]u8{ 's', 'e', 'q', 't' },
});
