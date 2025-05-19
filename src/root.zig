// MIT License
//
// This file is part of the bb project (github.com/haha-systems/bb).
//
// Copyright (c) 2025 Haha Systems Limited
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
const std = @import("std");
const testing = std.testing;

// Structure to hold .gitignore patterns for a directory
pub const IgnorePatterns = struct {
    patterns: std.ArrayList(Pattern),
    allocator: std.mem.Allocator,

    const Pattern = struct {
        pattern: []const u8,
        is_negated: bool,
        is_directory: bool,
    };

    pub fn init(allocator: std.mem.Allocator) IgnorePatterns {
        return .{ .patterns = std.ArrayList(Pattern).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *IgnorePatterns) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern.pattern);
        }
        self.patterns.deinit();
    }

    pub fn addPattern(self: *IgnorePatterns, pattern: []const u8, is_negated: bool, is_directory: bool) !void {
        const dup_pattern = try self.allocator.dupe(u8, pattern);
        try self.patterns.append(.{ .pattern = dup_pattern, .is_negated = is_negated, .is_directory = is_directory });
    }
};

// Check if a file or directory should be ignored
pub fn shouldIgnore(
    dir_path: []const u8,
    name: []const u8,
    is_directory: bool,
    ignore_map: *std.StringHashMap(IgnorePatterns),
) !bool {
    const patterns = ignore_map.get(dir_path) orelse return false;
    var ignored = false;
    for (patterns.patterns.items) |pattern| {
        if (pattern.is_negated) continue;
        if (match(pattern.pattern, name, is_directory)) {
            ignored = true;
            break;
        }
    }
    if (!ignored) return false;
    for (patterns.patterns.items) |pattern| {
        if (pattern.is_negated and match(pattern.pattern, name, is_directory)) {
            return false;
        }
    }
    return true;
}

// Load .gitignore patterns from a directory
pub fn loadGitignore(allocator: std.mem.Allocator, dir_path: []const u8, ignore_map: *std.StringHashMap(IgnorePatterns)) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .access_sub_paths = true }) catch return;
    defer dir.close();

    var patterns = IgnorePatterns.init(allocator);
    var file = dir.openFile(".gitignore", .{ .mode = .read_only }) catch return;
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var reader = buf_reader.reader();
    var line_buf: [1024]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const is_negated = trimmed[0] == '!';
        const pattern = if (is_negated) trimmed[1..] else trimmed;
        const is_directory = std.mem.endsWith(u8, pattern, "/");
        try patterns.addPattern(pattern, is_negated, is_directory);
    }
    if (patterns.patterns.items.len > 0) {
        try ignore_map.put(try allocator.dupe(u8, dir_path), patterns);
    } else {
        patterns.deinit();
    }
}

// Glob pattern matching function supporting * and ? and .gitignore syntax
pub fn match(pattern: []const u8, name: []const u8, is_directory: bool) bool {
    var pat = pattern;
    var is_dir_pattern = false;
    if (std.mem.endsWith(u8, pattern, "/")) {
        is_dir_pattern = true;
        pat = pattern[0 .. pattern.len - 1];
    }
    if (is_dir_pattern and !is_directory) return false;

    var pattern_i: usize = 0;
    var name_i: usize = 0;
    var next_pattern_i: usize = 0;
    var next_name_i: usize = 0;
    while (pattern_i < pat.len or name_i < name.len) {
        if (pattern_i < pat.len) {
            const c = pat[pattern_i];
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

// Recursively add watches for all non-ignored subdirectories
pub fn addRecursiveWatches(
    allocator: std.mem.Allocator,
    inotify_fd: std.posix.fd_t,
    dir_path: []const u8,
    watch_map: *std.AutoHashMap(i32, []u8),
    ignore_map: *std.StringHashMap(IgnorePatterns),
    events: u32,
) !void {
    if (try shouldIgnore(std.fs.path.dirname(dir_path) orelse dir_path, std.fs.path.basename(dir_path), true, ignore_map)) {
        std.log.info("Skipping ignored directory: {s}", .{dir_path});
        return;
    }

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .access_sub_paths = true, .iterate = true });
    defer dir.close();

    const wd = try std.posix.inotify_add_watch(inotify_fd, dir_path, events);
    try watch_map.put(wd, try allocator.dupe(u8, dir_path));
    std.log.info("Watching directory {s}, watch descriptor: {}", .{ dir_path, wd });

    try loadGitignore(allocator, dir_path, ignore_map);

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .directory) {
            const subdir_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            try addRecursiveWatches(allocator, inotify_fd, subdir_path, watch_map, ignore_map, events);
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
