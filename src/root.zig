//! RIFF (Resource Interchange File Format) parser and serializer library for Zig.
//!
//! This library provides functionality to parse, manipulate, and serialize RIFF format files.
//! RIFF is a generic file container format used by many multimedia formats including WAV, AVI, and WebP.
//!
//! ## Overview
//!
//! RIFF files consist of chunks, where each chunk has:
//! - A 4-byte identifier (FourCC)
//! - A 4-byte size field (little-endian)
//! - Data payload
//!
//! This library supports three types of chunks:
//! - **Basic chunks**: Simple data containers with a FourCC and data payload
//! - **LIST chunks**: Containers that hold multiple sub-chunks
//! - **RIFF chunks**: The root container that defines the file type
//!
//! ## Usage Example
//!
//! ```zig
//! const std = @import("std");
//! const riff = @import("riff_zig");
//!
//! var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//! defer _ = gpa.deinit();
//! const allocator = gpa.allocator();
//!
//! // Create a WAVE file structure
//! const format_data = "..."; // Your format chunk data
//! const audio_data = "...";  // Your audio sample data
//! const wave_chunk = riff.Chunk{ .riff = .{
//!     .four_cc = "WAVE".*,
//!     .chunks = &[_]riff.Chunk{
//!         .{ .chunk = .{ .four_cc = "fmt ".*, .data = format_data } },
//!         .{ .chunk = .{ .four_cc = "data".*, .data = audio_data } },
//!     },
//! }};
//!
//! // Serialize to file
//! const file = try std.fs.cwd().createFile("output.wav", .{});
//! defer file.close();
//! try riff.to_writer(wave_chunk, allocator, file.writer());
//!
//! // Parse from file
//! const data = try std.fs.cwd().readFileAlloc(allocator, "input.wav", 1024 * 1024);
//! defer allocator.free(data);
//! const parsed = try riff.from_slice(allocator, data);
//! defer parsed.deinit(allocator);
//! ```
//!
//! ## API Functions
//!
//! - `from_slice`: Parse a RIFF chunk from binary data
//! - `to_writer`: Serialize a RIFF chunk to a writer
//! - `Chunk.deinit`: Free allocated memory for a chunk and its children

const std = @import("std");

pub const FourCC = struct {
    inner: [4]u8,

    pub const NewError = error{InvalidFormat};

    pub fn new(four_cc: []const u8) NewError!FourCC {
        if (four_cc.len != 4)
            return error.InvalidFormat;

        return FourCC{
            .inner = four_cc[0..4].*,
        };
    }
};

/// Represents a RIFF (Resource Interchange File Format) chunk.
/// Models the three types of chunks that can appear in RIFF files.
pub const Chunk = union(enum) {
    /// A basic RIFF chunk with a FourCC identifier and data payload.
    /// The `four_cc` is a 4-byte identifier (e.g., "fmt ", "data").
    chunk: struct {
        four_cc: FourCC,
        data: []const u8,
    },
    /// A LIST chunk containing a list of sub-chunks.
    list: []const Chunk,
    /// A RIFF chunk representing the root container of a RIFF file.
    /// The `four_cc` specifies the file type (e.g., "WAVE").
    riff: struct {
        four_cc: FourCC,
        chunks: []const Chunk,
    },

    /// Deallocates memory if chunks were dynamically allocated.
    pub fn deinit(self: Chunk, allocator: std.mem.Allocator) void {
        switch (self) {
            .chunk => |b| allocator.free(b.data),
            .list => |l| {
                for (l) |child| child.deinit(allocator);
                allocator.free(l);
            },
            .riff => |r| {
                for (r.chunks) |child| child.deinit(allocator);
                allocator.free(r.chunks);
            },
        }
    }
};

pub const ToChunkListError = error{
    /// The input data does not conform to the expected RIFF format structure.
    InvalidFormat,
    /// The actual data size does not match the size specified in the header.
    SizeMismatch,
};

/// Converts a RIFF chunk to its binary representation and writes it to a writer.
/// Serialization follows the RIFF specification: Header (4 bytes FourCC) + Size (4 bytes, little-endian) + Data.
///
/// Parameters:
///   - `chunk`: The RIFF chunk to serialize (can be .chunk, .list, or .riff variant).
///   - `allocator`: Memory allocator used for temporary buffers during serialization.
///   - `writer`: The writer interface to output the serialized data (e.g., file, buffer).
///
/// Returns: `void` on success.
///
/// Errors:
///   - Writer errors (including memory allocation failures) from `std.Io.Writer.Error`.
pub fn to_writer(chunk: Chunk, allocator: std.mem.Allocator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (chunk) {
        .chunk => |b| {
            try writer.writeAll(&b.four_cc.inner);
            try writer.writeInt(u32, @intCast(b.data.len), .little);
            try writer.writeAll(b.data);
        },
        .list => |l| {
            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            for (l) |child| try to_writer(child, allocator, &w.writer);

            const written_bytes = w.written();

            try writer.writeAll("LIST");
            try writer.writeInt(u32, @intCast(written_bytes.len), .little);
            try writer.writeAll(written_bytes);
        },
        .riff => |r| {
            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            for (r.chunks) |child| try to_writer(child, allocator, &w.writer);

            const written_bytes = w.written();

            try writer.writeAll("RIFF");
            try writer.writeInt(u32, @intCast(written_bytes.len + 4), .little);
            try writer.writeAll(&r.four_cc.inner);
            try writer.writeAll(written_bytes);
        },
    }
}

/// Parses a RIFF chunk from binary data.
/// Supports parsing of basic chunks, LIST chunks, and RIFF container chunks.
///
/// Parameters:
///   - `allocator`: Memory allocator for creating the chunk structure and its data.
///   - `bytes`: The raw binary data containing a RIFF chunk to parse.
///
/// Returns: A `Chunk` instance representing the parsed data.
///
/// Errors:
///   - `InvalidFormat`: If the data is too short or malformed (from `ToChunkListError` or `FourCC.NewError`).
///   - `SizeMismatch`: If the chunk size doesn't match the available data (from `ToChunkListError`).
///   - `OutOfMemory`: If memory allocation fails during parsing (from `std.mem.Allocator.Error`).
pub fn from_slice(allocator: std.mem.Allocator, bytes: []const u8) (ToChunkListError || std.mem.Allocator.Error || FourCC.NewError)!Chunk {
    if (bytes.len < 8) return error.InvalidFormat;

    const id = bytes[0..4];
    const size = std.mem.readInt(u32, bytes[4..8], .little);

    if (std.mem.eql(u8, id, "RIFF")) {
        if (bytes.len < 12) return error.InvalidFormat;
        const four_cc = bytes[8..12];
        const chunks = try to_chunk_list(allocator, bytes[12..]);
        return Chunk{ .riff = .{ .four_cc = try FourCC.new(four_cc), .chunks = chunks } };
    } else if (std.mem.eql(u8, id, "LIST")) {
        const chunks = try to_chunk_list(allocator, bytes[8..]);
        return Chunk{ .list = chunks };
    } else {
        const data_end = 8 + size;
        if (bytes.len < data_end) return error.SizeMismatch;
        const data = try allocator.dupe(u8, bytes[8..data_end]);
        return Chunk{ .chunk = .{ .four_cc = try FourCC.new(id), .data = data } };
    }
}

/// Internal helper function to parse a sequence of chunks from binary data.
/// Used by `from_slice` to parse the contents of LIST and RIFF chunks.
///
/// Parameters:
///   - `allocator`: Memory allocator for creating chunk structures.
///   - `bytes`: The raw binary data containing one or more sequential chunks.
///
/// Returns: A slice of parsed `Chunk` instances.
///
/// Errors:
///   - `InvalidFormat`: If any chunk header is incomplete (from `ToChunkListError` or `FourCC.NewError`).
///   - `SizeMismatch`: If any chunk size extends beyond available data (from `ToChunkListError`).
///   - `OutOfMemory`: If memory allocation fails during parsing (from `std.mem.Allocator.Error`).
fn to_chunk_list(allocator: std.mem.Allocator, bytes: []const u8) (ToChunkListError || std.mem.Allocator.Error || FourCC.NewError)![]const Chunk {
    var list: std.array_list.Aligned(Chunk, null) = .empty;
    errdefer {
        for (list.items) |c| c.deinit(allocator);
        list.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < bytes.len) {
        if (pos + 8 > bytes.len) return error.InvalidFormat;
        const id = bytes[pos .. pos + 4][0..4];
        const size = std.mem.readInt(u32, bytes[pos + 4 .. pos + 8][0..4], .little);
        const next_pos = pos + 8 + size;

        if (next_pos > bytes.len) return error.SizeMismatch;

        const chunk_data = try allocator.dupe(u8, bytes[pos + 8 .. next_pos]);
        try list.append(allocator, Chunk{ .chunk = .{
            .four_cc = try FourCC.new(id),
            .data = chunk_data,
        } });

        pos = next_pos;
    }

    return list.toOwnedSlice(allocator);
}

test "Wave" {
    _ = Chunk{ .riff = .{
        .four_cc = .{ .inner = "WAVE".* },
        .chunks = &[_]Chunk{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "" } },
        },
    } };
}

test "chunk serialization" {
    const allocator = std.testing.allocator;

    const chunk = Chunk{ .chunk = .{
        .four_cc = try FourCC.new("fmt "),
        .data = "EXAMPLE_DATA",
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try to_writer(chunk, allocator, &w.writer);
    const chunk_data = w.written();

    const expected = "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA";
    try std.testing.expectEqualSlices(u8, expected, chunk_data);

    const chunk_file: []const u8 = @embedFile("assets/chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, chunk_data);
}

test "list_chunk serialization" {
    const allocator = std.testing.allocator;

    const list_chunk = Chunk{ .list = &.{
        .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "EXAMPLE_DATA" } },
        .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "EXAMPLE_DATA" } },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try to_writer(list_chunk, allocator, &w.writer);
    const list_chunk_data: []u8 = w.written();

    const expected = "LIST" ++ "\x28\x00\x00\x00" ++ "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA" ++ "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA";
    try std.testing.expectEqualSlices(u8, expected, list_chunk_data);

    const chunk_file: []const u8 = @embedFile("assets/list_chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, list_chunk_data);
}

test "riff_chunk serialization" {
    const allocator = std.testing.allocator;

    const riff_chunk = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "" } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try to_writer(riff_chunk, allocator, &w.writer);
    const riff_chunk_data: []u8 = w.written();

    const expected = "RIFF" ++ "\x14\x00\x00\x00" ++ "TEST" ++ "fmt " ++ "\x00\x00\x00\x00" ++ "" ++ "data" ++ "\x00\x00\x00\x00" ++ "";
    try std.testing.expectEqualSlices(u8, expected, riff_chunk_data);

    const chunk_file: []const u8 = @embedFile("assets/riff_chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, riff_chunk_data);
}

test "chunk deserialization" {
    const allocator = std.testing.allocator;

    const chunk_filedata: []const u8 = @embedFile("assets/chunk.riff");
    const chunk: Chunk = try from_slice(allocator, chunk_filedata);
    defer chunk.deinit(allocator);
    const expected = Chunk{ .chunk = .{
        .four_cc = try FourCC.new("fmt "),
        .data = "EXAMPLE_DATA",
    } };

    try std.testing.expectEqualDeep(expected, chunk);
}

test "list_chunk deserialization" {
    const allocator = std.testing.allocator;

    const list_chunk_filedata: []const u8 = @embedFile("assets/list_chunk.riff");
    const list_chunk: Chunk = try from_slice(allocator, list_chunk_filedata);
    defer list_chunk.deinit(allocator);
    const expected = Chunk{ .list = &.{
        .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "EXAMPLE_DATA" } },
        .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "EXAMPLE_DATA" } },
    } };

    try std.testing.expectEqualDeep(expected, list_chunk);
}

test "riff_chunk deserialization" {
    const allocator = std.testing.allocator;

    const riff_chunk_filedata: []const u8 = @embedFile("assets/riff_chunk.riff");
    const riff_chunk: Chunk = try from_slice(allocator, riff_chunk_filedata);
    defer riff_chunk.deinit(allocator);
    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "" } },
        },
    } };

    try std.testing.expectEqualDeep(expected, riff_chunk);
}
