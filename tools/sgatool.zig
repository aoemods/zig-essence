const std = @import("std");
const sga = @import("sga");

fn decompress(allocator: std.mem.Allocator, args: [][:0]const u8) !void {
    if (args.len != 2) return error.InvalidArgs;

    var archive_path = args[0];
    var out_dir_path = args[1];

    var archive_file = try std.fs.cwd().openFile(archive_path, .{});
    defer archive_file.close();
    std.fs.cwd().makeDir(out_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => @panic("Could not create output directory!"),
    };
    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{ .access_sub_paths = true });
    defer out_dir.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    var data_buf = std.ArrayList(u8).init(arena_allocator);
    _ = data_buf;

    var archive = try sga.Archive.fromFile(arena_allocator, archive_file);
    for (archive.root_nodes.items) |node|
        try writeTreeToFileSystem(archive_file.reader(), &data_buf, node, out_dir);
}

// TODO: Modularize code

fn tree(allocator: std.mem.Allocator, args: [][:0]const u8) !void {
    if (args.len != 1) return error.InvalidArgs;

    var archive_path = args[0];

    var archive_file = try std.fs.cwd().openFile(archive_path, .{});
    defer archive_file.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();
    defer arena.deinit();

    var archive = try sga.Archive.fromFile(arena_allocator, archive_file);
    for (archive.root_nodes.items) |node|
        try node.printTree(0);
}

// TODO: Move some of this functionality to a decompress in `sga.zig`
fn writeTreeToFileSystem(reader: anytype, data_buf: *std.ArrayList(u8), node: sga.Node, dir: std.fs.Dir) anyerror!void {
    var name = switch (node) {
        .toc => |f| f.name,
        .folder => |f| f.name,
        .file => |f| f.name,
    };

    if (node.getChildren()) |children| {
        dir.makeDir(name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => @panic("oof"),
        };
        var sub_dir = try dir.openDir(name, .{ .access_sub_paths = true });
        defer sub_dir.close();

        for (children.items) |child|
            try writeTreeToFileSystem(reader, data_buf, child, sub_dir);
    } else {
        var file = try dir.createFile(name, .{});
        defer file.close();

        var writer = file.writer();

        switch (node.file.entry.storage_type) {
            .stream_compress, .buffer_compress => {
                var window: [0x8000]u8 = undefined;
                try reader.context.seekTo(node.file.header.data_offset + node.file.entry.data_offset + 2);
                var stream = std.compress.deflate.inflateStream(reader, &window);

                try data_buf.ensureTotalCapacity(node.file.entry.compressed_length);
                data_buf.items.len = node.file.entry.compressed_length;

                _ = try stream.reader().readAll(data_buf.items);
                switch (node.file.entry.verification_type) {
                    .none => {},
                    else => {}, // TODO: Implement
                    // else => std.log.info("File {s}'s integrity not verified: {s} not implemented", .{ node.file.name, node.file.entry.verification_type }),
                }
                try writer.writeAll(data_buf.items);
            },
            .store => {
                try data_buf.ensureTotalCapacity(node.file.entry.uncompressed_length);
                try reader.context.seekTo(node.file.header.data_offset + node.file.entry.data_offset);
                data_buf.items.len = node.file.entry.uncompressed_length;

                _ = try reader.readAll(data_buf.items);
                std.debug.assert(std.hash.Crc32.hash(data_buf.items) == node.file.entry.crc);
                try writer.writeAll(data_buf.items);
            },
        }
    }
}

fn compress(allocator: std.mem.Allocator, args: [][:0]const u8) !void {
    if (args.len != 2) return error.InvalidArgs;

    var header: sga.SGAHeader = undefined;
    header.version = 10;
    header.product = .essence;
    header.offset = header.calcOffset();
    _ = allocator;

    var dir = try std.fs.cwd().openDir(args[0], .{ .access_sub_paths = true, .iterate = true });
    defer dir.close();

    var out_file = try std.fs.cwd().createFile(args[1], .{});
    defer out_file.close();

    // std.log.info("{d}", .{header.calcOffset()});

    // const writer = out_file.writer();
    // try header.encode(writer);

    // _ = allocator;
    // var header: sga.SGAHeader = undefined;
}

fn xor(allocator: std.mem.Allocator, args: [][:0]const u8) !void {
    _ = allocator;
    if (args.len != 1) return error.InvalidArgs;

    var file = try std.fs.cwd().openFile(args[0], .{ .write = true });
    defer file.close();

    var header = try sga.SGAHeader.decode(file.reader());
    header.signature = [_]u8{ 00, 00, 00, 00, 00, 00, 00, 00 } ** 32;
    try header.encode(file.writer());
}

fn printHelp() void {
    std.debug.print(
        \\
        \\sgatool [decompress|compress|tree] ...
        \\    decompress <archive_path> <out_dir_path>
        \\    compress <dir_path> <out_archive_path>
        \\    tree <archive_path>
        \\
        \\    xor <archive_path>
        \\
        \\NOTE: compress and decompress use the first directory layer as the TOC entries
        \\NOTE 2: at the moment, compress does not support *actual* file compression or md5/sha hashing, it'll just
        \\lump your files into the SGA unhashed and uncompressed :P
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, args[1], "decompress")) {
        decompress(allocator, args[2..]) catch |err| switch (err) {
            error.InvalidArgs => printHelp(),
            else => std.log.err("{s}", .{err}),
        };
    } else if (std.mem.eql(u8, args[1], "compress")) {
        compress(allocator, args[2..]) catch |err| switch (err) {
            error.InvalidArgs => printHelp(),
            else => std.log.err("{s}", .{err}),
        };
    } else if (std.mem.eql(u8, args[1], "tree")) {
        tree(allocator, args[2..]) catch |err| switch (err) {
            error.InvalidArgs => printHelp(),
            else => std.log.err("{s}", .{err}),
        };
    } else if (std.mem.eql(u8, args[1], "xor")) {
        xor(allocator, args[2..]) catch |err| switch (err) {
            error.InvalidArgs => printHelp(),
            else => std.log.err("{s}", .{err}),
        };
    } else {
        printHelp();
    }
}
