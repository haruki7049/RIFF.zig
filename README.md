# RIFF.zig

RIFF (Resource Interchange File Format) parser and serializer library for Zig.

## Features

- **Parse and Serialize**: Full support for reading and writing RIFF format files.
- **Support for Multiple Chunk Types**:
  - **Basic Chunks**: Simple data containers with a FourCC and payload.
  - **LIST Chunks**: Containers for grouping multiple sub-chunks.
  - **RIFF Chunks**: The root container defining the file type (e.g., WAVE, AVI).
- **Zig Native**: Designed for Zig 0.16.0+, leveraging its memory management and error handling.

## Documents

For the main branch documentations, see [haruki7049.github.io/RIFF.zig](https://haruki7049.github.io/RIFF.zig).

## Installation

Add `riff_zig` to your `build.zig.zon` dependencies:

```zig
.{
    .name = "your_project",
    .version = "0.1.0",
    .dependencies = .{
        .riff_zig = .{
            .url = "https://github.com/haruki7049/riff.zig/archive/<commit_hash>.tar.gz",
            .hash = "<hash>",
        },
    },
}
```

Then in your `build.zig`:

```zig
// Import the riff_zig module
const riff_zig = b.dependency("riff_zig", .{});
// Add the module to your executable
exe.root_module.addImport("riff_zig", riff_zig.module("riff_zig"));
```

## Usage Example

The following example demonstrates how to create and serialize a WAVE file structure.

```zig
const std = @import("std");
const riff = @import("riff_zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Define a WAVE file structure using RIFF chunks
    const wave_chunk = riff.Chunk{ .riff = .{
        .four_cc = try riff.FourCC.new("WAVE"),
        .chunks = &[_]riff.Chunk{
            // Define a format chunk
            .{ .chunk = .{ .four_cc = try riff.FourCC.new("fmt "), .data = "format_data" } },
            // Define a data chunk
            .{ .chunk = .{ .four_cc = try riff.FourCC.new("data"), .data = "audio_data" } },
        },
    } };

    // Create an output file
    const file = try std.Io.Dir.cwd().createFile(io, "output.wav", .{});
    defer file.close(io);

    // write() takes a *std.Io.Writer: wrap the file in a buffered File.Writer,
    // pass its `.interface`, then flush so the buffered bytes reach the file.
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try riff.write(wave_chunk, &file_writer.interface);
    try file_writer.interface.flush();
}
```

## Concurrent I/O

`read()` and `write()` never call `std.Io` themselves - they only operate
on the `*std.Io.Reader`/`*std.Io.Writer` interface you hand them. Whether
a call blocks the calling context or runs concurrently with other work is
therefore entirely up to the `std.Io` implementation you pass when
building that reader/writer (e.g. `std.Io.Threaded`, the thread-pool-backed
implementation every `std.process.Init.io` uses by default), so no
separate "async" API is needed: wrap the call in `io.async()` at the call
site.

```zig
const std = @import("std");
const riff = @import("riff_zig");

fn parseFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !riff.Chunk {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);
    var reader: std.Io.Reader = .fixed(data);
    return riff.read(allocator, &reader);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Runs on a worker thread; the calling thread is free to make progress
    // on other work while the parse is in flight.
    var future = io.async(parseFile, .{ io, allocator, "input.wav" });
    // ... do other work here ...
    const chunk = try future.await(io);
    defer chunk.deinit(allocator);
}
```

The same applies to `write()`: wrap the call (and whatever writer setup it
needs) in a function passed to `io.async()`.

## API Overview

- `riff.read(allocator, reader)`: Parses a RIFF chunk from a binary stream.
- `riff.write(chunk, writer)`: Serializes a chunk to binary format.
- `Chunk.deinit(allocator)`: Recursively frees memory allocated for a chunk.
- `riff.stream.readTree(allocator, reader, options)`: Builds the chunk tree that `riff.read()` returns. Pass `Options.total_len` when the input length is known to have the declared size checked up front.
- `riff.stream.Iterator`: A pull-style streaming parser. `Iterator.init(reader, options)` and `next()` yield one event per chunk header, and a chunk's payload is read only on request (`data()`, `readDataAlloc()`, `dataReader()`), so large files need not be loaded into memory.

## License

This project is dual-licensed under the **MIT License** and **Apache License 2.0**.
