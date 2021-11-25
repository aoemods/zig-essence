const std = @import("std");
const sga = @import("sga");

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

    pub fn getChildren(self: Node) std.ArrayListUnmanaged(Node) {
        return switch (self) {
            .toc => |f| f.children,
            .folder => |f| f.children,
            .file => |f| f.children,
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

        for (self.getChildren().items) |child|
            child.printTree(level + 1);
    }
};

pub const TOC = struct {
    name: []const u8,
    alt_name: []const u8,

    children: std.ArrayListUnmanaged(Node),

    pub fn init(name: []const u8, alt_name: []const u8, children: std.ArrayListUnmanaged(Node)) TOC {
        var toc: TOC = undefined;

        toc.name = name;
        toc.alt_name = alt_name;
        toc.children = children;

        return toc;
    }
};

pub const Folder = struct {
    name: []const u8,
    parent: *Node,
    children: std.ArrayListUnmanaged(Node),

    pub fn init(name: []const u8, children: std.ArrayListUnmanaged(Node)) Folder {
        var folder: Folder = undefined;

        folder.name = name;
        folder.children = children;

        return folder;
    }
};

pub const File = struct {
    name: []const u8,
    parent: *Node,
    children: std.ArrayListUnmanaged(Node),

    pub fn init(name: []const u8, children: std.ArrayListUnmanaged(Node)) File {
        var file: File = undefined;

        file.name = name;
        file.children = children;

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
    header: sga.SGAHeader,
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
            var folder = Folder.init(name, children);
            var folder_node = Node{ .folder = folder };
            folder_node.propagateParent(children);
            try node_list.append(allocator, folder_node);
        } else try node_list.appendSlice(allocator, children.toOwnedSlice(allocator));
    }
    //   for (uint index = fileStartIndex; index < fileEndIndex; ++index)
    //   {
    //     long fileOffset = dataOffset + fileData[(int) index].dataOffset;
    //     string name = this.ReadDynamicString(reader, stringOffset + (long) fileData[(int) index].nameOffset);
    //     if (name == null && this.Version < (ushort) 6)
    //     {
    //       long offset = fileOffset - 260L;
    //       name = this.m_fileStream.Seek(offset, SeekOrigin.Begin) != offset ? string.Format("File_{0}.dat", (object) index) : this.ReadFixedString(reader, 256, 1);
    //     }
    //     uint? crc32 = new uint?();
    //     if (this.Version >= (ushort) 6)
    //       crc32 = new uint?(fileData[(int) index].crc);
    //     nodeList.Add((INode) new File(this, name, fileData[(int) index].storeLength, fileData[(int) index].length, fileData[(int) index].verificationType, fileData[(int) index].storageType, fileOffset, crc32));
    //   }
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
    std.fs.cwd().makeDir(out_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => @panic("oof"),
    };
    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{ .access_sub_paths = true });

    _ = archive_file;
    _ = out_dir;

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

    for (toc_entries.items) |toc| {
        var children = try createChildren(allocator, reader, header, folder_entries, file_entries, toc.folder_root_index, toc.folder_root_index + 1, 0, 0, &name_last, &name_buf);
        var toc_node = Node{ .toc = TOC.init(dezero(&toc.name), dezero(&toc.alias), children) };
        toc_node.propagateParent(children);

        toc_node.printTree(0);
    }
}
