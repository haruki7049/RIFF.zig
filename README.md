# RIFF.zig

RIFF (Resource Interchange File Format) parser and serializer library for Zig.

## Features

- **Parse and Serialize**: Full support for reading and writing RIFF format files.
- **Support for Multiple Chunk Types**:
- **Basic Chunks**: Simple data containers with a FourCC and payload.
- **LIST Chunks**: Containers for grouping multiple sub-chunks.
- **RIFF Chunks**: The root container defining the file type (e.g., WAVE, AVI).
- **Zig Native**: Designed for Zig 0.15.2+, leveraging its memory management and error handling.

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
const riff_zig = b.dependency("riff_zig", .{
    .target = target,
    .optimize = optimize,
});
// Add the module to your executable
exe.root_module.addImport("riff_zig", riff_zig.module("riff_zig"));
```

## Usage Example

The following example demonstrates how to create and serialize a WAVE file structure.

```zig
const std = @import("std");
const riff = @import("riff_zig");

pub fn main() !void {
    // Initialize a General Purpose Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define a WAVE file structure using RIFF chunks
    const wave_chunk = riff.Chunk{ .riff = .{
        .four_cc = try riff.FourCC.new("WAVE"),
        .chunks = &[_]riff.Chunk{
            // Define a format chunk
            .{ .chunk = .{ .four_cc = try riff.FourCC.new("fmt "), .data = "format_data" } },
            // Define a data chunk
            .{ .chunk = .{ .four_cc = try riff.FourCC.new("data"), .data = "audio_data" } },
        },
    }};

    // Create an output file
    const file = try std.fs.cwd().createFile("output.wav", .{});
    defer file.close();

    // Serialize the chunk structure to the file
    try riff.write(wave_chunk, allocator, file.writer());
}
```

## API Overview

- `riff.read(allocator, reader)`: Parses a RIFF chunk from a binary stream.
- `riff.write(chunk, allocator, writer)`: Serializes a chunk to binary format.
- `Chunk.deinit(allocator)`: Recursively frees memory allocated for a chunk.

## Development

This project uses [Nix](https://nixos.org/) for the development environment.

```sh
nix develop
zig build test
```

## License

This project is dual-licensed under the **MIT License** and **Apache License 2.0**.
