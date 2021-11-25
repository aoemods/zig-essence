const std = @import("std");
const sga = @import("sga");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.print(
            \\sgatool <archive> <out_dir>
            \\
            \\
        , .{});
    }
}
