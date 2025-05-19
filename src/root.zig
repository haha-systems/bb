//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

// Glob pattern matching function supporting * and ?
pub fn match(pattern: []const u8, name: []const u8) bool {
    var pattern_i: usize = 0;
    var name_i: usize = 0;
    var next_pattern_i: usize = 0;
    var next_name_i: usize = 0;
    while (pattern_i < pattern.len or name_i < name.len) {
        if (pattern_i < pattern.len) {
            const c = pattern[pattern_i];
            switch (c) {
                '?' => {
                    if (name_i < name.len) {
                        pattern_i += 1;
                        name_i += 1;
                        continue;
                    }
                },
                '*' => {
                    next_pattern_i = pattern_i;
                    next_name_i = name_i + 1;
                    pattern_i += 1;
                    continue;
                },
                else => {
                    if (name_i < name.len and name[name_i] == c) {
                        pattern_i += 1;
                        name_i += 1;
                        continue;
                    }
                },
            }
        }
        if (next_name_i > 0 and next_name_i <= name.len) {
            pattern_i = next_pattern_i;
            name_i = next_name_i;
            continue;
        }
        return false;
    }
    return true;
}

// Convert path to absolute and verify it's a directory
pub fn getAbsoluteDirPath(allocator: std.mem.Allocator, input_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(input_path)) {
        var dir = try std.fs.openDirAbsolute(input_path, .{ .access_sub_paths = true });
        dir.close();
        return input_path;
    }
    var abs_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fs.cwd().realpath(input_path, &abs_path_buffer);
    std.log.info("Converted relative path {s} to absolute path: {s}", .{ input_path, abs_path });
    var dir = try std.fs.openDirAbsolute(abs_path, .{ .access_sub_paths = true });
    dir.close();
    return try allocator.dupe(u8, abs_path);
}

// Recursively add watches for all subdirectories
pub fn addRecursiveWatches(
    allocator: std.mem.Allocator,
    inotify_fd: std.posix.fd_t,
    dir_path: []const u8,
    watch_map: *std.AutoHashMap(i32, []const u8),
    events: u32,
) !void {
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .access_sub_paths = true, .iterate = true });
    defer dir.close();

    const wd = try std.posix.inotify_add_watch(inotify_fd, dir_path, events);
    try watch_map.put(wd, try allocator.dupe(u8, dir_path));
    std.log.info("Watching directory {s}, watch descriptor: {}", .{ dir_path, wd });

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .directory) {
            const subdir_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            try addRecursiveWatches(allocator, inotify_fd, subdir_path, watch_map, events);
        }
    }
}

test "main:match_wildcard" {
    const pattern = "test*.zig";
    const name = "test.zig";
    const result = match(pattern, name);
    try std.testing.expect(result);

    const name2 = "example.zig";
    const result2 = match(pattern, name2);
    try std.testing.expect(!result2);

    const pattern2 = "*.zig";
    const result3 = match(pattern2, name);
    try std.testing.expect(result3);
}

test "main:match_question" {
    const pattern = "test?.zig";
    const name = "test1.zig";
    const result = match(pattern, name);
    try std.testing.expect(result);

    const name2 = "test12.zig";
    const result2 = match(pattern, name2);
    try std.testing.expect(!result2);

    const pattern2 = "?est?.zig";
    const result3 = match(pattern2, name);
    try std.testing.expect(result3);
}
