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
//!     .four_cc = riff.FourCC.new("WAVE"),
//!     .chunks = &[_]riff.Chunk{
//!         .{ .chunk = .{ .four_cc = riff.FourCC.new("fmt "), .data = format_data } },
//!         .{ .chunk = .{ .four_cc = riff.FourCC.new("data"), .data = audio_data } },
//!     },
//! }};
//!
//! // Serialize to file
//! const file = try std.fs.cwd().createFile("output.wav", .{});
//! defer file.close();
//! try riff.write(wave_chunk, allocator, file.writer());
//!
//! // Parse from file
//! const data = try std.fs.cwd().readFileAlloc(allocator, "input.wav", 1024 * 1024);
//! defer allocator.free(data);
//! var reader = std.Io.Reader.fixed(data);
//! const parsed = try riff.read(allocator, &reader);
//! defer parsed.deinit(allocator);
//! ```
//!
//! ## API Functions
//!
//! - `read`: Parse a RIFF chunk from a reader
//! - `write`: Serialize a RIFF chunk to a writer
//! - `Chunk.deinit`: Free allocated memory for a chunk and its children

const std = @import("std");

/// Represents a Four-Character Code (FourCC) identifier used in RIFF chunks.
/// A FourCC is a 4-byte sequence that identifies the type of a chunk (e.g., "WAVE", "fmt ", "data").
/// FourCC codes are case-sensitive and commonly used in multimedia file formats.
pub const FourCC = struct {
    /// The 4-byte array containing the FourCC identifier.
    inner: [4]u8,

    /// Error type for FourCC creation failures.
    pub const NewError = error{
        /// Returned when the input string is not exactly 4 bytes long.
        InvalidFormat,
    };

    /// Creates a new FourCC from a byte slice.
    ///
    /// Parameters:
    ///   - `four_cc`: A byte slice that must be exactly 4 bytes long.
    ///
    /// Returns: A new `FourCC` instance on success.
    ///
    /// Errors:
    ///   - `InvalidFormat`: If the input slice length is not exactly 4 bytes.
    pub fn new(four_cc: []const u8) NewError!FourCC {
        if (four_cc.len != 4)
            return error.InvalidFormat;

        return FourCC{
            .inner = four_cc[0..4].*,
        };
    }
};

/// Represents a RIFF (Resource Interchange File Format) chunk.
/// Models the three types of chunks that can appear in RIFF files:
///
/// ## Chunk Variants
///
/// - **chunk**: A basic RIFF chunk with a FourCC identifier and data payload.
///   Used for leaf nodes in the RIFF tree structure (e.g., "fmt ", "data" chunks in WAVE files).
///
/// - **list**: A LIST chunk containing a list of sub-chunks.
///   Used to group related chunks together without specifying a file type.
///
/// - **riff**: A RIFF chunk representing the root container of a RIFF file.
///   This is typically the outermost chunk and specifies the file type (e.g., "WAVE", "AVI").
///
/// ## Memory Management
///
/// Chunks created by `read()` allocate memory that must be freed using `deinit()`.
/// Chunks created with static data (using `&[_]Chunk{...}` syntax) may not need `deinit()`.
pub const Chunk = union(enum) {
    /// A basic RIFF chunk with a FourCC identifier and data payload.
    /// The `four_cc` is a 4-byte identifier (e.g., "fmt ", "data").
    /// The `data` field contains the chunk's payload bytes.
    chunk: struct {
        four_cc: FourCC,
        data: []const u8,
    },
    /// A LIST chunk containing a list of sub-chunks.
    /// LIST chunks are used to group multiple chunks together.
    list: []const Chunk,
    /// A RIFF chunk representing the root container of a RIFF file.
    /// The `four_cc` specifies the file type (e.g., "WAVE" for audio files).
    /// The `chunks` field contains all sub-chunks within this RIFF container.
    riff: struct {
        four_cc: FourCC,
        chunks: []const Chunk,
    },

    /// Deallocates memory for this chunk and all of its children recursively.
    /// This method should be called when you're done using a chunk that was
    /// created by `read()` or manually allocated with an allocator.
    ///
    /// For `.chunk` variants: Frees the data buffer.
    /// For `.list` variants: Recursively frees all child chunks, then the list itself.
    /// For `.riff` variants: Recursively frees all child chunks, then the chunks array.
    ///
    /// Parameters:
    ///   - `allocator`: The same allocator that was used to create this chunk.
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

/// Error types that can occur during RIFF chunk parsing.
pub const ToChunkListError = error{
    /// The input data does not conform to the expected RIFF format structure.
    /// This can happen if chunk headers are incomplete or malformed.
    InvalidFormat,
    /// The actual data size does not match the size specified in the chunk header.
    /// This typically indicates corrupted or truncated RIFF data.
    SizeMismatch,
};

/// Serializes a RIFF chunk to its binary representation and writes it to a writer.
///
/// This function converts a `Chunk` structure into the binary RIFF format according to the specification.
/// The serialization format depends on the chunk variant:
///
/// ## Serialization Format
///
/// - **Basic chunk (.chunk)**:
///   - FourCC identifier (4 bytes)
///   - Data size (4 bytes, little-endian u32) - size of the data payload only
///   - Data payload (variable length)
///
/// - **LIST chunk (.list)**:
///   - "LIST" identifier (4 bytes)
///   - Data size (4 bytes, little-endian u32) - size of all serialized sub-chunks only
///   - Serialized sub-chunks (variable length)
///
/// - **RIFF chunk (.riff)**:
///   - "RIFF" identifier (4 bytes)
///   - Data size (4 bytes, little-endian u32) - size of FourCC (4) + all serialized sub-chunks
///   - File type FourCC (4 bytes, e.g., "WAVE")
///   - Serialized sub-chunks (variable length)
///
/// ## Usage
///
/// The function recursively serializes nested chunks. For `.list` and `.riff` variants,
/// temporary buffers are used to calculate sizes before writing to the output writer.
///
/// Parameters:
///   - `chunk`: The RIFF chunk to serialize (can be `.chunk`, `.list`, or `.riff` variant).
///   - `allocator`: Memory allocator used for temporary buffers during serialization of LIST and RIFF chunks.
///   - `writer`: The writer interface to output the serialized binary data (e.g., `file.writer()`, `std.Io.Writer`).
///
/// Returns: `void` on success.
///
/// Errors:
///   - Any error from the writer (e.g., `WriteError`, disk full, connection errors).
///   - `OutOfMemory`: If temporary buffer allocation fails for LIST or RIFF chunks.
pub fn write(chunk: Chunk, allocator: std.mem.Allocator, writer: anytype) anyerror!void {
    switch (chunk) {
        .chunk => |b| {
            try writer.writeAll(&b.four_cc.inner);
            try writer.writeInt(u32, @intCast(b.data.len), .little);
            try writer.writeAll(b.data);
        },
        .list => |l| {
            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            for (l) |child| try write(child, allocator, &w.writer);

            const written_bytes = w.written();

            try writer.writeAll("LIST");
            try writer.writeInt(u32, @intCast(written_bytes.len), .little);
            try writer.writeAll(written_bytes);
        },
        .riff => |r| {
            var w = std.Io.Writer.Allocating.init(allocator);
            defer w.deinit();
            for (r.chunks) |child| try write(child, allocator, &w.writer);

            const written_bytes = w.written();

            try writer.writeAll("RIFF");
            try writer.writeInt(u32, @intCast(written_bytes.len + 4), .little);
            try writer.writeAll(&r.four_cc.inner);
            try writer.writeAll(written_bytes);
        },
    }
}

/// Parses a RIFF chunk from a reader containing binary RIFF data.
///
/// This function reads binary data from the reader and constructs a `Chunk` structure
/// representing the parsed RIFF data. The function automatically detects the chunk type
/// based on the FourCC identifier and handles parsing accordingly.
///
/// ## Supported Chunk Types
///
/// - **RIFF chunks**: Root container chunks with a file type identifier (e.g., "WAVE", "AVI").
///   The function expects at least 12 bytes: "RIFF" (4) + size (4) + type FourCC (4).
///
/// - **LIST chunks**: Container chunks that hold multiple sub-chunks.
///   The function expects at least 8 bytes: "LIST" (4) + size (4), followed by sub-chunks.
///
/// - **Basic chunks**: Leaf chunks with a FourCC identifier and data payload.
///   The function expects at least 8 bytes: FourCC (4) + size (4), followed by data.
///
/// ## Memory Allocation
///
/// The function allocates memory for:
/// - Chunk data payloads (copied from the reader buffer)
/// - Arrays of sub-chunks for LIST and RIFF containers
///
/// All allocated memory must be freed by calling `chunk.deinit(allocator)` when done.
///
/// ## Data Format
///
/// The reader must provide a buffer with the complete chunk data in little-endian format:
/// - FourCC identifiers are 4-byte ASCII sequences
/// - Size fields are 32-bit little-endian unsigned integers
/// - Data follows immediately after the size field
///
/// Parameters:
///   - `allocator`: Memory allocator for creating the chunk structure and allocating data buffers.
///   - `reader`: The reader interface to read RIFF chunk binary data from (must have a `buffered()` method).
///
/// Returns: A `Chunk` instance representing the parsed data. The caller owns the memory and must call `deinit()`.
///
/// Errors:
///   - `InvalidFormat`: If the data buffer is too short (< 8 bytes for basic chunks, < 12 for RIFF chunks) or chunk headers are malformed.
///   - `SizeMismatch`: If the declared chunk size extends beyond the available data in the buffer.
///   - `OutOfMemory`: If memory allocation fails during parsing (from `std.mem.Allocator.Error`).
pub fn read(allocator: std.mem.Allocator, reader: anytype) (ToChunkListError || std.mem.Allocator.Error || FourCC.NewError)!Chunk {
    const buffer = reader.buffered();

    if (buffer.len < 8)
        return error.InvalidFormat;

    const id = buffer[0..4];
    const size = std.mem.readInt(u32, buffer[4..8], .little);

    if (std.mem.eql(u8, id, "RIFF")) {
        if (buffer.len < 12)
            return error.InvalidFormat;

        const four_cc = buffer[8..12];
        const chunks = try to_chunk_list(allocator, buffer[12..]);
        return Chunk{ .riff = .{ .four_cc = try FourCC.new(four_cc), .chunks = chunks } };
    } else if (std.mem.eql(u8, id, "LIST")) {
        const chunks = try to_chunk_list(allocator, buffer[8..]);
        return Chunk{ .list = chunks };
    } else {
        const data_end = 8 + size;

        if (buffer.len < data_end)
            return error.SizeMismatch;

        const data = try allocator.dupe(u8, buffer[8..data_end]);
        return Chunk{ .chunk = .{ .four_cc = try FourCC.new(id), .data = data } };
    }
}

/// Internal helper function to parse a sequence of chunks from binary data.
/// Used by `read` to parse the contents of LIST and RIFF chunks.
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
        // Need at least 8 bytes for chunk header (FourCC + size)
        if (pos + 8 > bytes.len) {
            // If we have leftover bytes that can't form a valid chunk header,
            // this is not necessarily an error - it could be padding
            // But we should check if there are any non-zero bytes
            var has_data = false;
            for (bytes[pos..]) |b| {
                if (b != 0) {
                    has_data = true;
                    break;
                }
            }
            if (has_data) {
                return error.InvalidFormat;
            }
            break;
        }

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
        .four_cc = try FourCC.new("WAVE"),
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
    try write(chunk, allocator, &w.writer);
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
    try write(list_chunk, allocator, &w.writer);
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
    try write(riff_chunk, allocator, &w.writer);
    const riff_chunk_data: []u8 = w.written();

    const expected = "RIFF" ++ "\x14\x00\x00\x00" ++ "TEST" ++ "fmt " ++ "\x00\x00\x00\x00" ++ "" ++ "data" ++ "\x00\x00\x00\x00" ++ "";
    try std.testing.expectEqualSlices(u8, expected, riff_chunk_data);

    const chunk_file: []const u8 = @embedFile("assets/riff_chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, riff_chunk_data);
}

test "Webp serialization" {
    const allocator = std.testing.allocator;
    const assertion_data = @import("./assertion_data.zig");

    const webp = Chunk{ .riff = .{
        .four_cc = try FourCC.new("WEBP"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("VP8X"), .data = assertion_data.VP8X.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("VP8 "), .data = assertion_data.VP8.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("EXIF"), .data = assertion_data.EXIF.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("XMP "), .data = assertion_data.XMP.data } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(webp, allocator, &w.writer);
    const webp_data: []u8 = w.written();

    const webp_file: []const u8 = @embedFile("assets/test_DJ.webp");
    try std.testing.expectEqualSlices(u8, webp_file, webp_data);
}

test "chunk deserialization" {
    const allocator = std.testing.allocator;

    const chunk_filedata: []const u8 = @embedFile("assets/chunk.riff");
    var reader = std.Io.Reader.fixed(chunk_filedata);
    const chunk: Chunk = try read(allocator, &reader);
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
    var reader = std.Io.Reader.fixed(list_chunk_filedata);
    const list_chunk: Chunk = try read(allocator, &reader);
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
    var reader = std.Io.Reader.fixed(riff_chunk_filedata);
    const riff_chunk: Chunk = try read(allocator, &reader);
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

test "Webp deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = @import("./assertion_data.zig");

    const filedata: []const u8 = @embedFile("assets/test_DJ.webp");
    var reader = std.Io.Reader.fixed(filedata);
    const riff_chunk: Chunk = try read(allocator, &reader);
    defer riff_chunk.deinit(allocator);

    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("WEBP"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("VP8X"), .data = assertion_data.VP8X.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("VP8 "), .data = assertion_data.VP8.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("EXIF"), .data = assertion_data.EXIF.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("XMP "), .data = assertion_data.XMP.data } },
        },
    } };

    try std.testing.expectEqualDeep(expected, riff_chunk);
}
