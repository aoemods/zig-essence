const std = @import("std");
const sga = @import("sga");

// TODO: Fix memory management; doesn't matter much because memory is freed on exit anyways
// but it'd still be cool if this program wasn't as totally garbage as the original

// TODO: Make sga strings []const u8s, "fixed length" really means "maximum length"
pub fn dezero(str: []const u8) []const u8 {
    return std.mem.span(@ptrCast([*:0]const u8, str));
}

// TODO: Move child logic to some higher level interface in package and not tooling
pub const Node = union(enum) {
    toc: TOC,
    folder: Folder,
    file: File,

    pub fn getParent(self: Node) ?*Node {
        return switch (self) {
            .toc => null,
            .folder => |f| f.parent,
            .file => |f| f.parent,
        };
    }

    pub fn getChildren(self: Node) ?std.ArrayListUnmanaged(Node) {
        return switch (self) {
            .toc => |f| f.children,
            .folder => |f| f.children,
            .file => null,
        };
    }

    pub fn propagateParent(self: *Node, children: std.ArrayListUnmanaged(Node)) void {
        for (children.items) |*child| {
            if (child.* != .folder) {
                if (child.* == .file) {
                    child.file.parent = self;
                }
            } else {
                child.folder.parent = self;
            }
        }
    }

    pub fn printTree(self: Node, level: usize) void {
        var l: usize = 0;
        while (l < level * 4) : (l += 1)
            std.debug.print(" ", .{});

        var name = switch (self) {
            .toc => |f| f.name,
            .folder => |f| f.name,
            .file => |f| f.name,
        };
        std.debug.print("{s}\n", .{name});

        if (self.getChildren()) |children|
            for (children.items) |child|
                child.printTree(level + 1);
    }
};

pub const TOC = struct {
    name: []const u8,
    alt_name: []const u8,
    children: std.ArrayListUnmanaged(Node),

    header: *const sga.SGAHeader,
    entry: *const sga.TOCEntry,

    pub fn init(name: []const u8, alt_name: []const u8, children: std.ArrayListUnmanaged(Node), header: *const sga.SGAHeader, entry: *const sga.TOCEntry) TOC {
        var toc: TOC = undefined;

        toc.name = name;
        toc.alt_name = alt_name;
        toc.children = children;

        toc.header = header;
        toc.entry = entry;

        return toc;
    }
};

pub const Folder = struct {
    name: []const u8,
    parent: *Node,
    children: std.ArrayListUnmanaged(Node),

    header: *const sga.SGAHeader,
    entry: *const sga.FolderEntry,

    pub fn init(name: []const u8, children: std.ArrayListUnmanaged(Node), header: *const sga.SGAHeader, entry: *const sga.FolderEntry) Folder {
        var folder: Folder = undefined;

        folder.name = name;
        folder.children = children;

        folder.header = header;
        folder.entry = entry;

        return folder;
    }
};

pub const File = struct {
    name: []const u8,
    parent: *Node,

    header: *const sga.SGAHeader,
    entry: *const sga.FileEntry,

    pub fn init(name: []const u8, header: *const sga.SGAHeader, entry: *const sga.FileEntry) File {
        var file: File = undefined;

        file.name = name;

        file.header = header;
        file.entry = entry;

        return file;
    }
};

fn readDynamicString(reader: anytype, name_last: *usize, name_buf: *std.ArrayList(u8), offset: usize) ![]const u8 {
    var old_pos = try reader.context.getPos();
    try reader.context.seekTo(offset);
    try sga.SGAHeader.readDynamicString(reader, name_buf.writer());
    try reader.context.seekTo(old_pos);

    var name = name_buf.items[name_last.*..];
    name_last.* = name_buf.items.len;

    return name;
}

fn createChildren(
    allocator: *std.mem.Allocator,
    //
    reader: anytype,
    header: *const sga.SGAHeader,
    //
    folder_entries: std.ArrayList(sga.FolderEntry),
    file_entries: std.ArrayList(sga.FileEntry),
    //
    folder_start_index: u32,
    folder_end_index: u32,
    //
    file_start_index: u32,
    file_end_index: u32,
    //
    name_last: *usize,
    name_buf: *std.ArrayList(u8),
) anyerror!std.ArrayListUnmanaged(Node) {
    var node_list = try std.ArrayListUnmanaged(Node).initCapacity(allocator, folder_end_index - folder_start_index + file_end_index - file_start_index);
    var folder_index: usize = folder_start_index;
    while (folder_index < folder_end_index) : (folder_index += 1) {
        var name = try readDynamicString(reader, name_last, name_buf, header.offset + header.string_offset + folder_entries.items[folder_index].name_offset);

        var maybe_index = std.mem.lastIndexOfAny(u8, name, &[_]u8{ '/', '\\' });
        if (maybe_index) |index|
            name = name[index + 1 ..];
        var children = try createChildren(allocator, reader, header, folder_entries, file_entries, folder_entries.items[folder_index].folder_start_index, folder_entries.items[folder_index].folder_end_index, folder_entries.items[folder_index].file_start_index, folder_entries.items[folder_index].file_end_index, name_last, name_buf);
        if (name.len > 0) {
            var folder = Folder.init(name, children, header, &folder_entries.items[folder_index]);
            var folder_node = Node{ .folder = folder };
            folder_node.propagateParent(children);
            try node_list.append(allocator, folder_node);
        } else try node_list.appendSlice(allocator, children.toOwnedSlice(allocator));
    }

    var file_index: usize = file_start_index;
    while (file_index < file_end_index) : (file_index += 1) {
        // var file_offset = header.data_offset + file_entries.items[file_index].data_offset;
        var name = try readDynamicString(reader, name_last, name_buf, header.offset + header.string_offset + file_entries.items[file_index].name_offset);
        // if (name == null && this.Version < (ushort) 6)
        // {
        //   long offset = fileOffset - 260L;
        //   name = this.m_fileStream.Seek(offset, SeekOrigin.Begin) != offset ? string.Format("File_{0}.dat", (object) index) : this.ReadFixedString(reader, 256, 1);
        // } TODO: handle this nasty case
        try node_list.append(allocator, Node{ .file = File.init(name, header, &file_entries.items[file_index]) });
    }
    return node_list;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.print(
            \\sgatool <archive_path> <out_dir_path>
            \\
            \\
        , .{});
        return;
    }

    var archive_path = args[1];
    var out_dir_path = args[2];

    var archive_file = try std.fs.cwd().openFile(archive_path, .{});
    defer archive_file.close();
    std.fs.cwd().makeDir(out_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => @panic("oof"),
    };
    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{ .access_sub_paths = true });
    defer out_dir.close();

    const reader = archive_file.reader();

    var header = try sga.SGAHeader.decode(reader);
    std.log.info("Archive name is \"{s}\"", .{std.unicode.fmtUtf16le(header.nice_name[0..])});

    // TOC
    try archive_file.seekTo(header.offset + header.toc_data_offset);

    var toc_entries = try std.ArrayList(sga.TOCEntry).initCapacity(allocator, header.toc_data_count);
    var toc_index: usize = 0;

    while (toc_index < header.toc_data_count) : (toc_index += 1)
        try toc_entries.append(try sga.TOCEntry.decode(reader, header));

    // Folders
    try archive_file.seekTo(header.offset + header.folder_data_offset);

    var folder_entries = try std.ArrayList(sga.FolderEntry).initCapacity(allocator, header.folder_data_count);
    var folder_index: usize = 0;

    while (folder_index < header.folder_data_count) : (folder_index += 1)
        try folder_entries.append(try sga.FolderEntry.decode(reader, header));

    // Files
    try archive_file.seekTo(header.offset + header.file_data_offset);

    var file_entries = try std.ArrayList(sga.FileEntry).initCapacity(allocator, header.file_data_count);
    var file_index: usize = 0;

    while (file_index < header.file_data_count) : (file_index += 1)
        try file_entries.append(try sga.FileEntry.decode(reader, header));

    // Make the tree
    var name_last: usize = 0;
    var name_buf = std.ArrayList(u8).init(allocator);
    var data_buf = std.ArrayList(u8).init(allocator);

    for (toc_entries.items) |toc| {
        var children = try createChildren(allocator, reader, &header, folder_entries, file_entries, toc.folder_root_index, toc.folder_root_index + 1, 0, 0, &name_last, &name_buf);
        var toc_node = Node{ .toc = TOC.init(dezero(&toc.name), dezero(&toc.alias), children, &header, &toc) };
        toc_node.propagateParent(children);

        try writeTree(reader, &data_buf, toc_node, out_dir);
    }
}

pub fn writeTree(reader: anytype, data_buf: *std.ArrayList(u8), node: Node, dir: std.fs.Dir) anyerror!void {
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
            try writeTree(reader, data_buf, child, sub_dir);
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
                try writer.writeAll(data_buf.items);
            },
            else => @panic("Not impl!"),
        }
    }
}
