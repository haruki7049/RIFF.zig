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
//! pub fn main(init: std.process.Init) !void {
//!     const allocator = init.gpa;
//!     const io = init.io;
//!
//!     // Create a WAVE file structure
//!     const format_data = "..."; // Your format chunk data
//!     const audio_data = "...";  // Your audio sample data
//!     const wave_chunk = riff.Chunk{ .riff = .{
//!         .four_cc = try riff.FourCC.new("WAVE"),
//!         .chunks = &[_]riff.Chunk{
//!             .{ .chunk = .{ .four_cc = try riff.FourCC.new("fmt "), .data = format_data } },
//!             .{ .chunk = .{ .four_cc = try riff.FourCC.new("data"), .data = audio_data } },
//!         },
//!     } };
//!
//!     // Serialize to file. write() takes a *std.Io.Writer, so wrap the file
//!     // in a buffered File.Writer and pass its `.interface`, then flush.
//!     const out_file = try std.Io.Dir.cwd().createFile(io, "output.wav", .{});
//!     defer out_file.close(io);
//!     var out_buffer: [4096]u8 = undefined;
//!     var file_writer = out_file.writer(io, &out_buffer);
//!     try riff.write(wave_chunk, allocator, &file_writer.interface);
//!     try file_writer.interface.flush();
//!
//!     // Parse from file. read() only inspects reader.buffered() (see
//!     // "Buffering Requirement" on `read`), so load the whole file up
//!     // front and wrap it with a fixed reader rather than streaming it.
//!     const data = try std.Io.Dir.cwd().readFileAlloc(io, "input.wav", allocator, .unlimited);
//!     defer allocator.free(data);
//!     var reader = std.Io.Reader.fixed(data);
//!     const parsed = try riff.read(allocator, &reader);
//!     defer parsed.deinit(allocator);
//! }
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
    /// A LIST chunk containing a type identifier and a list of sub-chunks.
    /// LIST chunks are used to group multiple chunks together under a named type
    /// (e.g., "INFO" for metadata, "sdta" for sample data in SoundFont files).
    list: struct {
        four_cc: FourCC,
        chunks: []const Chunk,
    },
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
    /// For `.list` variants: Recursively frees all child chunks, then the chunks array.
    /// For `.riff` variants: Recursively frees all child chunks, then the chunks array.
    ///
    /// Parameters:
    ///   - `allocator`: The same allocator that was used to create this chunk.
    pub fn deinit(self: Chunk, allocator: std.mem.Allocator) void {
        switch (self) {
            .chunk => |b| allocator.free(b.data),
            .list => |l| {
                for (l.chunks) |child| child.deinit(allocator);
                allocator.free(l.chunks);
            },
            .riff => |r| {
                for (r.chunks) |child| child.deinit(allocator);
                allocator.free(r.chunks);
            },
        }
    }
};

/// Maximum nesting depth of RIFF/LIST containers that `read()`/`to_chunk_list`
/// will descend into. Guards against a stack-overflow denial-of-service from
/// adversarial input with many trivially nested LIST chunks (each level costs
/// only 12 bytes: "LIST" + size + type FourCC), which would otherwise recurse
/// without bound.
pub const max_nesting_depth: usize = 64;

/// Error types that can occur during RIFF chunk parsing.
pub const ToChunkListError = error{
    /// The input data does not conform to the expected RIFF format structure.
    /// This can happen if chunk headers are incomplete or malformed.
    InvalidFormat,
    /// The actual data size does not match the size specified in the chunk header.
    /// This typically indicates corrupted or truncated RIFF data.
    SizeMismatch,
    /// RIFF/LIST container nesting exceeded `max_nesting_depth`.
    NestingTooDeep,
};

/// Error type returned by `read()`.
pub const ReadError = ToChunkListError || std.mem.Allocator.Error || FourCC.NewError;

/// Error type returned by `write()`.
pub const WriteError = std.Io.Writer.Error || error{
    /// A `.chunk`'s data length, or a `.list`/`.riff` chunk's serialized
    /// sub-chunk payload length, does not fit in a `u32` (RIFF size fields
    /// are 32-bit).
    PayloadTooLarge,
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
/// The function serializes nested chunks in two passes: first it computes
/// each `.list`/`.riff` container's total serialized size with a pure,
/// allocation-free walk of the tree (`container_children_size`), then it
/// streams the header and children directly to `writer`. No intermediate
/// buffer is built, so nested containers are not copied once per level.
///
/// Parameters:
///   - `chunk`: The RIFF chunk to serialize (can be `.chunk`, `.list`, or `.riff` variant).
///   - `allocator`: Unused by `write()` itself; kept for API stability. `write()` performs no
///     allocation of its own.
///   - `writer`: The `std.Io.Writer` to output the serialized binary data to (e.g. `&file_writer.interface`,
///     `&std.Io.Writer.Allocating.writer`).
///
/// Returns: `void` on success.
///
/// Errors: see `WriteError`.
///   - `std.Io.Writer.Error.WriteFailed`: If the writer fails (disk full, connection errors, etc.).
///   - `PayloadTooLarge`: If a `.chunk`'s data length, or any `.list`/`.riff` chunk's
///     serialized sub-chunk payload length, does not fit in a `u32` (RIFF size
///     fields are 32-bit).
pub fn write(chunk: Chunk, allocator: std.mem.Allocator, writer: *std.Io.Writer) WriteError!void {
    switch (chunk) {
        .chunk => |b| {
            const data_size = std.math.cast(u32, b.data.len) orelse return error.PayloadTooLarge;

            try writer.writeAll(&b.four_cc.inner);
            try writer.writeInt(u32, data_size, .little);
            try writer.writeAll(b.data);

            // Add padding byte if data size is odd
            if (b.data.len % 2 == 1) {
                try writer.writeByte(0);
            }
        },
        .list => |l| {
            const size = try container_children_size(l.chunks);

            try writer.writeAll("LIST");
            try writer.writeInt(u32, size, .little);
            try writer.writeAll(&l.four_cc.inner);
            for (l.chunks) |child| try write(child, allocator, writer);

            // Add padding byte if total data size is odd
            if (size % 2 == 1) {
                try writer.writeByte(0);
            }
        },
        .riff => |r| {
            const size = try container_children_size(r.chunks);

            try writer.writeAll("RIFF");
            try writer.writeInt(u32, size, .little);
            try writer.writeAll(&r.four_cc.inner);
            for (r.chunks) |child| try write(child, allocator, writer);

            // Add padding byte if total data size is odd
            if (size % 2 == 1) {
                try writer.writeByte(0);
            }
        },
    }
}

/// Computes the total serialized size (header + data/children + parity pad)
/// that `write()` would produce for `chunk`, without allocating or writing
/// anything. Used to determine a `.list`/`.riff` container's `size` field
/// before its header is written, so `write()` can stream children directly
/// to the real writer instead of buffering them first.
fn serialized_size(chunk: Chunk) error{PayloadTooLarge}!usize {
    return switch (chunk) {
        .chunk => |b| blk: {
            const data_size = std.math.cast(u32, b.data.len) orelse return error.PayloadTooLarge;
            break :blk 8 + @as(usize, data_size) + (data_size % 2);
        },
        .list => |l| blk: {
            const children_size = try container_children_size(l.chunks);
            break :blk 8 + @as(usize, children_size) + (children_size % 2);
        },
        .riff => |r| blk: {
            const children_size = try container_children_size(r.chunks);
            break :blk 8 + @as(usize, children_size) + (children_size % 2);
        },
    };
}

/// Sums `serialized_size` over `chunks` plus the 4-byte type FourCC that
/// precedes them inside a `.list`/`.riff` container, and checks the result
/// fits the u32 RIFF size field - this is exactly the value `write()` puts
/// in that container's own `size` field.
fn container_children_size(chunks: []const Chunk) error{PayloadTooLarge}!u32 {
    var total: usize = 4; // type FourCC
    for (chunks) |child| total += try serialized_size(child);
    return std.math.cast(u32, total) orelse error.PayloadTooLarge;
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
/// ## Buffering Requirement
///
/// `read()` only inspects whatever bytes are already available via `reader.buffered()`;
/// it never calls `fill`/`discard` or otherwise pulls more bytes from the underlying
/// source. This means `reader` must already have the *entire* chunk (including all
/// nested sub-chunks) sitting in its buffer before calling `read()`. A genuinely
/// streaming reader whose buffer is smaller than the data being parsed will fail with
/// `error.InvalidFormat` or `error.SizeMismatch` on otherwise valid RIFF data.
///
/// In practice this means reading the whole input into memory first and wrapping it
/// with `std.Io.Reader.fixed(data)`, as shown in the module-level usage example, rather
/// than passing a small-buffer streaming reader (e.g. a file reader with a small
/// internal buffer) directly.
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
///   - `reader`: The `std.Io.Reader` to read RIFF chunk binary data from. Its buffer must
///     already contain the entire chunk being parsed; see "Buffering Requirement" below.
///
/// Returns: A `Chunk` instance representing the parsed data. The caller owns the memory and must call `deinit()`.
///
/// Errors: see `ReadError`.
///   - `InvalidFormat`: If a chunk header is incomplete or malformed.
///   - `SizeMismatch`: If a chunk's declared size extends beyond the available buffered data.
///   - `NestingTooDeep`: If nested LIST containers exceed `max_nesting_depth`.
///   - `OutOfMemory`: If allocating a chunk's data payload or a sub-chunk array fails.
pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReadError!Chunk {
    // A chunk header is a FourCC (4 bytes) followed by a little-endian u32 size (4 bytes).
    const four_cc_len = 4;
    const header_len = four_cc_len + @sizeOf(u32);
    // RIFF/LIST containers have an extra type FourCC right after the header.
    const container_header_len = header_len + four_cc_len;

    const buffer = reader.buffered();

    if (buffer.len < header_len)
        return error.InvalidFormat;

    const id = buffer[0..four_cc_len];
    const size = std.mem.readInt(u32, buffer[four_cc_len..header_len], .little);

    if (std.mem.eql(u8, id, "RIFF")) {
        if (buffer.len < container_header_len or size < four_cc_len)
            return error.InvalidFormat;

        // Widen to usize before adding: `header_len` is a comptime_int with no
        // usize operand in this expression, so `header_len + size` would stay
        // u32-typed and overflow-panic for `size` near `maxInt(u32)`.
        const data_end: usize = header_len + @as(usize, size);
        if (buffer.len < data_end)
            return error.SizeMismatch;

        const four_cc = buffer[header_len..container_header_len];
        const chunks = try to_chunk_list(allocator, buffer[container_header_len..data_end], 0);
        return Chunk{ .riff = .{ .four_cc = try FourCC.new(four_cc), .chunks = chunks } };
    } else if (std.mem.eql(u8, id, "LIST")) {
        if (buffer.len < container_header_len or size < four_cc_len)
            return error.InvalidFormat;

        const data_end: usize = header_len + @as(usize, size);
        if (buffer.len < data_end)
            return error.SizeMismatch;

        const four_cc = buffer[header_len..container_header_len];
        const chunks = try to_chunk_list(allocator, buffer[container_header_len..data_end], 0);
        return Chunk{ .list = .{ .four_cc = try FourCC.new(four_cc), .chunks = chunks } };
    } else {
        const data_end: usize = header_len + @as(usize, size);

        if (buffer.len < data_end)
            return error.SizeMismatch;

        const data = try allocator.dupe(u8, buffer[header_len..data_end]);
        return Chunk{ .chunk = .{ .four_cc = try FourCC.new(id), .data = data } };
    }
}

/// Internal helper function to parse a sequence of chunks from binary data.
/// Used by `read` to parse the contents of LIST and RIFF chunks.
///
/// Parameters:
///   - `allocator`: Memory allocator for creating chunk structures.
///   - `bytes`: The raw binary data containing one or more sequential chunks.
///   - `depth`: Current nesting depth (0 for the children of the top-level
///     RIFF/LIST chunk `read()` parsed). Checked against `max_nesting_depth`
///     before descending into a nested LIST chunk, to bound recursion.
///
/// Returns: A slice of parsed `Chunk` instances.
///
/// Errors:
///   - `InvalidFormat`: If any chunk header is incomplete (from `ToChunkListError` or `FourCC.NewError`).
///   - `SizeMismatch`: If any chunk size extends beyond available data (from `ToChunkListError`).
///   - `NestingTooDeep`: If nested LIST containers exceed `max_nesting_depth`.
///   - `OutOfMemory`: If memory allocation fails during parsing (from `std.mem.Allocator.Error`).
fn to_chunk_list(allocator: std.mem.Allocator, bytes: []const u8, depth: usize) (ToChunkListError || std.mem.Allocator.Error || FourCC.NewError)![]const Chunk {
    if (depth > max_nesting_depth)
        return error.NestingTooDeep;

    var list: std.array_list.Aligned(Chunk, null) = .empty;
    errdefer {
        for (list.items) |c| c.deinit(allocator);
        list.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < bytes.len) {
        // Need at least 8 bytes for chunk header (FourCC + size)
        if (pos + 8 > bytes.len) {
            // The RIFF spec only pads a chunk with a single zero byte, to
            // keep the container's overall size even, after an odd-length
            // chunk (write() emits exactly one such byte). Anything else
            // here - more than one leftover byte, or a non-zero byte - is
            // not standard padding and likely indicates truncated/corrupted
            // data, so it must not be silently accepted.
            if (bytes.len - pos == 1 and bytes[pos] == 0) {
                break;
            }
            return error.InvalidFormat;
        }

        const id = bytes[pos .. pos + 4][0..4];
        const size = std.mem.readInt(u32, bytes[pos + 4 .. pos + 8][0..4], .little);
        const next_pos = pos + 8 + size;

        if (next_pos > bytes.len) return error.SizeMismatch;

        // A nested "RIFF" is handled identically to "LIST": both are just a
        // container header (id + size + type FourCC) followed by sub-chunks.
        // write() already serializes a nested `.riff` this way, so read() must
        // recognize it too, or the nested chunk round-trips back as an opaque
        // `.chunk` leaf instead of its original `.riff` structure.
        if (std.mem.eql(u8, id, "LIST") or std.mem.eql(u8, id, "RIFF")) {
            if (next_pos < pos + 12) return error.InvalidFormat;
            const container_type = bytes[pos + 8 .. pos + 12][0..4];
            const sub_chunks = try to_chunk_list(allocator, bytes[pos + 12 .. next_pos], depth + 1);
            errdefer {
                for (sub_chunks) |c| c.deinit(allocator);
                allocator.free(sub_chunks);
            }
            const four_cc = try FourCC.new(container_type);
            try list.append(allocator, if (std.mem.eql(u8, id, "LIST"))
                Chunk{ .list = .{ .four_cc = four_cc, .chunks = sub_chunks } }
            else
                Chunk{ .riff = .{ .four_cc = four_cc, .chunks = sub_chunks } });
        } else {
            const chunk_data = try allocator.dupe(u8, bytes[pos + 8 .. next_pos]);
            errdefer allocator.free(chunk_data);
            try list.append(allocator, Chunk{ .chunk = .{
                .four_cc = try FourCC.new(id),
                .data = chunk_data,
            } });
        }

        // RIFF chunks are padded to an even byte boundary: `write()` emits a
        // pad byte after odd-length data, but that pad byte is not counted in
        // `size`, so it must be skipped here before parsing the next sibling.
        pos = next_pos + (size % 2);
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

    const chunk_file: []const u8 = @embedFile("assets/riff-files/chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, chunk_data);
}

test "write returns PayloadTooLarge instead of panicking for oversized chunk data" {
    const allocator = std.testing.allocator;

    // Regression test: build a slice whose length exceeds u32 max without
    // actually allocating any memory for it. write() must reject this based
    // on `.len` alone, before ever writing (or dereferencing) `data`, so
    // constructing the slice from a dangling-but-unread pointer is safe here.
    const fake_len: usize = @as(usize, std.math.maxInt(u32)) + 1;
    const fake_data: []const u8 = @as([*]const u8, @ptrFromInt(1))[0..fake_len];
    const chunk = Chunk{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = fake_data } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try std.testing.expectError(error.PayloadTooLarge, write(chunk, allocator, &w.writer));
}

test "write performs no allocation for nested .list/.riff containers" {
    // Regression test: write()'s .list/.riff branches used to build each
    // nesting level's serialized children in a temporary
    // std.Io.Writer.Allocating buffer before copying it into the parent -
    // meaning every level needed at least one allocation, and the same bytes
    // were copied again at each level on the way up. write() now computes
    // container sizes with a pure, allocation-free helper and streams
    // children directly to the real writer, so it should need no allocation
    // at all. Pass an allocator that fails on the very first allocation
    // attempt, and a non-allocating fixed-buffer writer, so any allocation
    // anywhere in write() (its own, or the destination writer's) fails loudly.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();

    const nested = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .list = .{
                .four_cc = try FourCC.new("SUB1"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "hi" } },
                },
            } },
        },
    } };

    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(nested, allocator, &w);

    const expected = "RIFF" ++ "\x1a\x00\x00\x00" ++ "TEST" ++ "LIST" ++ "\x0e\x00\x00\x00" ++ "SUB1" ++ "data" ++ "\x02\x00\x00\x00" ++ "hi";
    try std.testing.expectEqualSlices(u8, expected, w.buffered());
}

test "list_chunk serialization" {
    const allocator = std.testing.allocator;

    const list_chunk = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "EXAMPLE_DATA" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "EXAMPLE_DATA" } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(list_chunk, allocator, &w.writer);
    const list_chunk_data: []u8 = w.written();

    const expected = "LIST" ++ "\x2c\x00\x00\x00" ++ "TEST" ++ "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA" ++ "fmt " ++ "\x0c\x00\x00\x00" ++ "EXAMPLE_DATA";
    try std.testing.expectEqualSlices(u8, expected, list_chunk_data);

    const chunk_file: []const u8 = @embedFile("assets/riff-files/list_chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, list_chunk_data);
}

test "list_chunk with an odd-sized chunk followed by a sibling chunk round-trips" {
    const allocator = std.testing.allocator;

    // Regression test: "odd1" has an odd-length payload (1 byte), so write()
    // appends a pad byte after it. read() must skip that pad byte before
    // parsing the next sibling chunk header ("even"), instead of desyncing.
    const list_chunk = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("odd1"), .data = "A" } },
            .{ .chunk = .{ .four_cc = try FourCC.new("even"), .data = "BB" } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(list_chunk, allocator, &w.writer);
    const list_chunk_data: []u8 = w.written();

    var reader = std.Io.Reader.fixed(list_chunk_data);
    const parsed: Chunk = try read(allocator, &reader);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualDeep(list_chunk, parsed);
}

test "a nested .riff chunk round-trips instead of losing its structure" {
    const allocator = std.testing.allocator;

    // Regression test: write() already serializes a nested `.riff` chunk
    // (nothing restricts `.riff` to the top level), but to_chunk_list() used
    // to only special-case "LIST", so a nested "RIFF" id fell through to the
    // generic leaf branch and came back as an opaque `.chunk` with undecoded
    // bytes instead of its original `.riff` structure.
    const list_chunk = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .riff = .{
                .four_cc = try FourCC.new("SUB1"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = "hi" } },
                },
            } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(list_chunk, allocator, &w.writer);
    const list_chunk_data: []u8 = w.written();

    var reader = std.Io.Reader.fixed(list_chunk_data);
    const parsed: Chunk = try read(allocator, &reader);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualDeep(list_chunk, parsed);
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

    const chunk_file: []const u8 = @embedFile("assets/riff-files/riff_chunk.riff");
    try std.testing.expectEqualSlices(u8, chunk_file, riff_chunk_data);
}

test "riff_chunk trailing bytes after the declared size are not absorbed as sub-chunks" {
    const allocator = std.testing.allocator;

    // Regression test: a well-formed, complete top-level RIFF chunk followed by
    // extra trailing bytes (e.g. concatenated files, trailer metadata) must not
    // have those trailing bytes parsed as additional sub-chunks; read() must
    // bound its parsing to the RIFF chunk's own declared `size`.
    const riff_chunk = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = "AB" } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(riff_chunk, allocator, &w.writer);
    const riff_chunk_data = w.written();

    const trailing = "JUNK" ++ "\x02\x00\x00\x00";
    const buffer = try allocator.alloc(u8, riff_chunk_data.len + trailing.len);
    defer allocator.free(buffer);
    @memcpy(buffer[0..riff_chunk_data.len], riff_chunk_data);
    @memcpy(buffer[riff_chunk_data.len..], trailing);

    var reader = std.Io.Reader.fixed(buffer);
    const parsed: Chunk = try read(allocator, &reader);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualDeep(riff_chunk, parsed);
}

test "read returns InvalidFormat for a buffer shorter than a chunk header" {
    const allocator = std.testing.allocator;

    const buffer = "abc"; // 3 bytes, less than the 8-byte header (FourCC + size)
    var reader = std.Io.Reader.fixed(buffer);
    try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
}

test "read returns InvalidFormat for a RIFF/LIST header without room for the type FourCC" {
    const allocator = std.testing.allocator;

    inline for (.{ "RIFF", "LIST" }) |id| {
        // 8 bytes: id + size, but no room left for the 4-byte type FourCC.
        const buffer = id ++ "\x04\x00\x00\x00";
        var reader = std.Io.Reader.fixed(buffer);
        try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
    }
}

test "read returns SizeMismatch when the declared size exceeds the remaining buffer" {
    const allocator = std.testing.allocator;

    // "data" chunk declares 10 bytes of payload, but only 2 bytes follow.
    const buffer = "data" ++ "\x0a\x00\x00\x00" ++ "AB";
    var reader = std.Io.Reader.fixed(buffer);
    try std.testing.expectError(error.SizeMismatch, read(allocator, &reader));
}

test "read returns SizeMismatch instead of panicking for a near-max declared size" {
    const allocator = std.testing.allocator;

    // Regression test: `header_len + size` has no usize operand of its own, so
    // it used to stay u32-typed and overflow-panic once `size` got within 7 of
    // `maxInt(u32)`, instead of read() reporting SizeMismatch like it does for
    // any other too-large declared size.
    const buffer = "data" ++ "\xff\xff\xff\xff" ++ "AB";
    var reader = std.Io.Reader.fixed(buffer);
    try std.testing.expectError(error.SizeMismatch, read(allocator, &reader));
}

test "read returns SizeMismatch instead of panicking for a near-max RIFF/LIST declared size" {
    const allocator = std.testing.allocator;

    inline for (.{ "RIFF", "LIST" }) |id| {
        const buffer = id ++ "\xff\xff\xff\xff" ++ "TEST";
        var reader = std.Io.Reader.fixed(buffer);
        try std.testing.expectError(error.SizeMismatch, read(allocator, &reader));
    }
}

test "read returns InvalidFormat for a nested LIST without room for its type FourCC" {
    const allocator = std.testing.allocator;

    // Nested LIST declares a 2-byte payload, leaving no room for its own
    // 4-byte type FourCC.
    const nested_list = "LIST" ++ "\x02\x00\x00\x00" ++ "XY";
    const buffer = "RIFF" ++ "\x0e\x00\x00\x00" ++ "TEST" ++ nested_list;

    var reader = std.Io.Reader.fixed(buffer);
    try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
}

test "read returns NestingTooDeep instead of overflowing the stack for excessively nested LIST chunks" {
    const allocator = std.testing.allocator;

    // Regression test: to_chunk_list() used to recurse once per nested LIST
    // chunk with no depth limit, so adversarial input with many trivially
    // nested LIST chunks (12 bytes of overhead each) could overflow the call
    // stack before any error was returned. Build a chain nested one level
    // deeper than max_nesting_depth and confirm read() reports
    // NestingTooDeep instead of crashing.

    // Innermost leaf: a plain chunk with no payload.
    var prev = try allocator.dupe(u8, "DATA" ++ "\x00\x00\x00\x00");
    defer allocator.free(prev);

    var depth: usize = 0;
    while (depth <= max_nesting_depth) : (depth += 1) {
        const size: u32 = @intCast(4 + prev.len); // type FourCC (4) + children (prev)
        const wrapped = try allocator.alloc(u8, 12 + prev.len);
        @memcpy(wrapped[0..4], "LIST");
        std.mem.writeInt(u32, wrapped[4..8], size, .little);
        @memcpy(wrapped[8..12], "TYPE");
        @memcpy(wrapped[12..], prev);
        allocator.free(prev);
        prev = wrapped;
    }

    const riff_size: u32 = @intCast(4 + prev.len);
    const buffer = try allocator.alloc(u8, 12 + prev.len);
    defer allocator.free(buffer);
    @memcpy(buffer[0..4], "RIFF");
    std.mem.writeInt(u32, buffer[4..8], riff_size, .little);
    @memcpy(buffer[8..12], "TEST");
    @memcpy(buffer[12..], prev);

    var reader = std.Io.Reader.fixed(buffer);
    try std.testing.expectError(error.NestingTooDeep, read(allocator, &reader));
}

test "to_chunk_list does not leak a chunk's data if appending it to the list fails" {
    // Regression test: if allocator.dupe() for a leaf chunk's data succeeded
    // but the subsequent list.append() then failed (e.g. array growth OOM),
    // the duplicated data was never freed - it wasn't yet part of list.items,
    // so to_chunk_list's own errdefer (which frees already-appended chunks)
    // never reached it. Sweep a few failure points instead of hardcoding the
    // exact internal allocation count, and rely on std.testing.allocator's
    // own leak detector to fail this test if anything goes unfreed.
    const buffer = "LIST" ++ "\x0e\x00\x00\x00" ++ "TEST" ++ "data" ++ "\x02\x00\x00\x00" ++ "AB";

    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var reader = std.Io.Reader.fixed(buffer);
        if (read(allocator, &reader)) |chunk| {
            chunk.deinit(allocator);
        } else |_| {}
    }
}

test "read accepts exactly one trailing zero pad byte inside a container but rejects more" {
    const allocator = std.testing.allocator;

    // Regression test: to_chunk_list() used to tolerate up to 7 trailing zero
    // bytes after the last chunk in a container as "padding", with no basis
    // in the RIFF spec (only a single pad byte, to keep the overall size
    // even, is ever standard). That could mask truncated/corrupted data as
    // valid. A single trailing zero byte must still be accepted; anything
    // beyond that must be rejected as InvalidFormat.
    const child = "data" ++ "\x02\x00\x00\x00" ++ "AB"; // even-sized, no pad needed

    {
        // Exactly one trailing zero byte: accepted.
        const children = child ++ "\x00";
        const buffer = "RIFF" ++ "\x0f\x00\x00\x00" ++ "TEST" ++ children;
        var reader = std.Io.Reader.fixed(buffer);
        const parsed = try read(allocator, &reader);
        defer parsed.deinit(allocator);
    }
    {
        // Two trailing zero bytes: rejected.
        const children = child ++ "\x00\x00";
        const buffer = "RIFF" ++ "\x10\x00\x00\x00" ++ "TEST" ++ children;
        var reader = std.Io.Reader.fixed(buffer);
        try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
    }
    {
        // One trailing non-zero byte: rejected.
        const children = child ++ "\x01";
        const buffer = "RIFF" ++ "\x0f\x00\x00\x00" ++ "TEST" ++ children;
        var reader = std.Io.Reader.fixed(buffer);
        try std.testing.expectError(error.InvalidFormat, read(allocator, &reader));
    }
}

test "FluidR3_GM2-2.sf2 serialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const sdta = struct {
            const smpl = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.sdta.smpl.data.bin");
            };
        };
        const pdta = struct {
            const phdr = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.phdr.data.bin");
            };
            const pbag = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.pbag.data.bin");
            };
            const pgen = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.pgen.data.bin");
            };
            const inst = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.inst.data.bin");
            };
            const ibag = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.ibag.data.bin");
            };
            const imod = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.imod.data.bin");
            };
            const igen = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.igen.data.bin");
            };
            const shdr = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.shdr.data.bin");
            };
        };
    };

    const soundfont = Chunk{ .riff = .{
        .four_cc = try FourCC.new("sfbk"),
        .chunks = &.{
            .{ .list = .{
                .four_cc = try FourCC.new("INFO"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("ifil"), .data = &.{ 2, 0, 2, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("INAM"), .data = "Fluid R3 GM" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("isng"), .data = "E-mu 10K1" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("IPRD"), .data = "SBAWE32" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ISFT"), .data = "SFEDT v1.28:SFEDT v1.36:" ++ .{ 0, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICOP"), .data = "Frank Wen 2000-2002" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICRD"), .data = "20th June 2013" ++ .{ 0, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("IENG"), .data = "Frank Wen" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICMT"), .data = "DO NOT REDISTRIBUTE ANY OF THESE SAMPLES. Violin fixed by Church Organist " ++ .{ 0, 0 } } },
                },
            } },
            .{ .list = .{
                .four_cc = try FourCC.new("sdta"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("smpl"), .data = assertion_data.sdta.smpl.data } },
                },
            } },
            .{ .list = .{
                .four_cc = try FourCC.new("pdta"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("phdr"), .data = assertion_data.pdta.phdr.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pbag"), .data = assertion_data.pdta.pbag.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pmod"), .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pgen"), .data = assertion_data.pdta.pgen.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("inst"), .data = assertion_data.pdta.inst.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ibag"), .data = assertion_data.pdta.ibag.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("imod"), .data = assertion_data.pdta.imod.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("igen"), .data = assertion_data.pdta.igen.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("shdr"), .data = assertion_data.pdta.shdr.data } },
                },
            } },
        },
    } };

    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try write(soundfont, allocator, &w.writer);
    const webp_data: []u8 = w.written();

    const webp_file: []const u8 = @embedFile("assets/riff-files/FluidR3_GM2-2.sf2");
    try std.testing.expectEqualSlices(u8, webp_file, webp_data);
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

    const webp_file: []const u8 = @embedFile("assets/riff-files/test_DJ.webp");
    try std.testing.expectEqualSlices(u8, webp_file, webp_data);
}

test "chunk deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const fmt = struct {
            const data = @embedFile("./assets/chunk-data/chunk.fmt.data");
        };
    };

    const chunk_filedata: []const u8 = @embedFile("assets/riff-files/chunk.riff");
    var reader = std.Io.Reader.fixed(chunk_filedata);
    const chunk: Chunk = try read(allocator, &reader);
    defer chunk.deinit(allocator);

    const expected = Chunk{ .chunk = .{
        .four_cc = try FourCC.new("fmt "),
        .data = assertion_data.fmt.data,
    } };

    try std.testing.expectEqualDeep(expected, chunk);
}

test "list_chunk deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const fmt1 = struct {
            const data = @embedFile("./assets/chunk-data/list.fmt1.data");
        };
        const fmt2 = struct {
            const data = @embedFile("./assets/chunk-data/list.fmt2.data");
        };
    };

    const list_chunk_filedata: []const u8 = @embedFile("assets/riff-files/list_chunk.riff");
    var reader = std.Io.Reader.fixed(list_chunk_filedata);
    const list_chunk: Chunk = try read(allocator, &reader);
    defer list_chunk.deinit(allocator);

    const expected = Chunk{ .list = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt1.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt2.data } },
        },
    } };

    try std.testing.expectEqualDeep(expected, list_chunk);
}

test "riff_chunk deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const fmt = struct {
            const data = @embedFile("./assets/chunk-data/riff_chunk.fmt.data");
        };
        const data = struct {
            const data = @embedFile("./assets/chunk-data/riff_chunk.data.data");
        };
    };

    const riff_chunk_filedata: []const u8 = @embedFile("assets/riff-files/riff_chunk.riff");
    var reader = std.Io.Reader.fixed(riff_chunk_filedata);
    const riff_chunk: Chunk = try read(allocator, &reader);
    defer riff_chunk.deinit(allocator);

    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt.data } },
            .{ .chunk = .{ .four_cc = try FourCC.new("data"), .data = assertion_data.data.data } },
        },
    } };

    try std.testing.expectEqualDeep(expected, riff_chunk);
}

test "riff_chunk_has_list deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const fmt1 = struct {
            const data = @embedFile("./assets/chunk-data/riff_chunk_has_list.fmt1.data");
        };
        const fmt2 = struct {
            const data = @embedFile("./assets/chunk-data/riff_chunk_has_list.fmt2.data");
        };
    };

    const chunk_filedata: []const u8 = @embedFile("assets/riff-files/riff_chunk_has_list.riff");
    var reader = std.Io.Reader.fixed(chunk_filedata);
    const chunk: Chunk = try read(allocator, &reader);
    defer chunk.deinit(allocator);

    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("TEST"),
        .chunks = &.{
            .{ .list = .{
                .four_cc = try FourCC.new("TEST"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt1.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("fmt "), .data = assertion_data.fmt2.data } },
                },
            } },
        },
    } };

    try std.testing.expectEqualDeep(expected, chunk);
}

test "FluidR3_GM2-2.sf2 deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = struct {
        const sdta = struct {
            const smpl = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.sdta.smpl.data.bin");
            };
        };
        const pdta = struct {
            const phdr = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.phdr.data.bin");
            };
            const pbag = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.pbag.data.bin");
            };
            const pgen = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.pgen.data.bin");
            };
            const inst = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.inst.data.bin");
            };
            const ibag = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.ibag.data.bin");
            };
            const imod = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.imod.data.bin");
            };
            const igen = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.igen.data.bin");
            };
            const shdr = struct {
                const data = @embedFile("./assets/chunk-data/FluidR3_GM2-2.sfbk.pdta.shdr.data.bin");
            };
        };
    };

    const chunk_filedata: []const u8 = @embedFile("assets/riff-files/FluidR3_GM2-2.sf2");
    var reader = std.Io.Reader.fixed(chunk_filedata);
    const chunk: Chunk = try read(allocator, &reader);
    defer chunk.deinit(allocator);

    const expected = Chunk{ .riff = .{
        .four_cc = try FourCC.new("sfbk"),
        .chunks = &.{
            .{ .list = .{
                .four_cc = try FourCC.new("INFO"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("ifil"), .data = &.{ 2, 0, 2, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("INAM"), .data = "Fluid R3 GM" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("isng"), .data = "E-mu 10K1" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("IPRD"), .data = "SBAWE32" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ISFT"), .data = "SFEDT v1.28:SFEDT v1.36:" ++ .{ 0, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICOP"), .data = "Frank Wen 2000-2002" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICRD"), .data = "20th June 2013" ++ .{ 0, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("IENG"), .data = "Frank Wen" ++ .{0} } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ICMT"), .data = "DO NOT REDISTRIBUTE ANY OF THESE SAMPLES. Violin fixed by Church Organist " ++ .{ 0, 0 } } },
                },
            } },
            .{ .list = .{
                .four_cc = try FourCC.new("sdta"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("smpl"), .data = assertion_data.sdta.smpl.data } },
                },
            } },
            .{ .list = .{
                .four_cc = try FourCC.new("pdta"),
                .chunks = &.{
                    .{ .chunk = .{ .four_cc = try FourCC.new("phdr"), .data = assertion_data.pdta.phdr.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pbag"), .data = assertion_data.pdta.pbag.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pmod"), .data = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 } } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("pgen"), .data = assertion_data.pdta.pgen.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("inst"), .data = assertion_data.pdta.inst.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("ibag"), .data = assertion_data.pdta.ibag.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("imod"), .data = assertion_data.pdta.imod.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("igen"), .data = assertion_data.pdta.igen.data } },
                    .{ .chunk = .{ .four_cc = try FourCC.new("shdr"), .data = assertion_data.pdta.shdr.data } },
                },
            } },
        },
    } };

    try std.testing.expectEqualDeep(expected, chunk);
}

test "Webp deserialization" {
    const allocator = std.testing.allocator;
    const assertion_data = @import("./assertion_data.zig");

    const filedata: []const u8 = @embedFile("assets/riff-files/test_DJ.webp");
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
