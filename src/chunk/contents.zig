const id = @import("./id.zig");

pub const Data = struct {
    id: id.ChunkID,
    data: []const u8,
};

pub const Childlen = struct {
    id: id.ChunkID,
    child_id: id.ChunkID,
    contents: Contents,
};

pub const ChildlenNoType = struct {
    child_id: id.ChunkID,
    contents: Contents,
};

pub const Contents = union {
    data: Data,
    childlen: Childlen,
    children_no_type: ChildlenNoType,
};
