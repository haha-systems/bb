const std = @import("std");
const os = std.os;
const mem = std.mem;

// Glob pattern matching function supporting * and ?
fn match(pattern: []const u8, name: []const u8) bool {
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
fn getAbsoluteDirPath(allocator: std.mem.Allocator, input_path: []const u8) ![]const u8 {
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
fn addRecursiveWatches(
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

pub fn main() !void {
    // Ensure the program runs on Linux
    if (@import("builtin").os.tag != .linux) {
        std.log.err("This program only works on Linux.", .{});
        return;
    }

    // Set up allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse command-line arguments
    var args = try std.process.argsAlloc(allocator);
    if (args.len < 4) {
        std.log.info("Usage: {s} <directory> <pattern> -- <command> [args...]", .{args[0]});
        return error.InvalidArguments;
    }
    defer allocator.free(args);

    var command_start: ?usize = null;
    for (args, 0..) |arg, i| {
        if (mem.eql(u8, arg, "--")) {
            command_start = i;
            break;
        }
    }

    if (command_start == null or command_start.? < 2 or command_start.? + 1 >= args.len) {
        std.log.err("Must provide directory, pattern, and command after --", .{});
        std.log.info("Usage: {s} <directory> <pattern> -- <command> [args...]", .{args[0]});
        return error.InvalidArguments;
    }

    const input_path = args[1];
    const pattern = args[2];
    const command_args = args[command_start.? + 1 ..];

    // Convert path to absolute and verify it's a directory
    const path = try getAbsoluteDirPath(allocator, input_path);
    std.log.info("Monitoring directory: {s}, pattern: {s}, command: {s}", .{ path, pattern, command_args[0] });

    // Initialize inotify
    const inotify_fd = try std.posix.inotify_init1(0);
    defer std.posix.close(inotify_fd);

    // Map watch descriptors to directory paths
    var watch_map = std.AutoHashMap(i32, []const u8).init(allocator);
    defer watch_map.deinit();

    // Recursively add watches for the directory and its subdirectories
    try addRecursiveWatches(allocator, inotify_fd, path, &watch_map, os.linux.IN.CLOSE_WRITE | os.linux.IN.CREATE | os.linux.IN.MOVED_TO | os.linux.IN.DELETE);

    // Define inotify event structure (fixed part)
    const std_inotify_event_fixed = extern struct {
        wd: i32,
        mask: u32,
        cookie: u32,
        len: u32,
    };

    // Event loop
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(inotify_fd, &buffer);
        std.log.debug("Read {d} bytes from inotify", .{n});

        var offset: usize = 0;
        while (offset < n) {
            const fixed_event: *const std_inotify_event_fixed = @ptrCast(@alignCast(&buffer[offset]));
            const event_len = fixed_event.len;
            const name_start = offset + @sizeOf(std_inotify_event_fixed);
            const name_end = name_start + event_len;
            if (name_end > n) {
                std.log.debug("Incomplete event at offset {d}, skipping", .{offset});
                break;
            }

            const name = buffer[name_start..name_end];
            const null_pos = mem.indexOfScalar(u8, name, 0) orelse name.len;
            const file_name = name[0..null_pos];

            const dir_path = watch_map.get(fixed_event.wd) orelse {
                std.log.debug("Unknown watch descriptor {d}, skipping", .{fixed_event.wd});
                offset = name_end;
                continue;
            };

            std.log.debug("Event: wd: {d}, mask: {x}, cookie: {d}, dir: {s}, name: {s}", .{ fixed_event.wd, fixed_event.mask, fixed_event.cookie, dir_path, file_name });

            // Handle directory creation
            if (fixed_event.mask & os.linux.IN.CREATE != 0 and fixed_event.mask & os.linux.IN.ISDIR != 0) {
                const new_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, file_name });
                std.log.info("New directory detected: {s}, adding watch", .{new_dir_path});
                try addRecursiveWatches(allocator, inotify_fd, new_dir_path, &watch_map, os.linux.IN.CLOSE_WRITE | os.linux.IN.CREATE | os.linux.IN.MOVED_TO | os.linux.IN.DELETE);
            }
            // Handle directory deletion
            else if (fixed_event.mask & os.linux.IN.DELETE != 0 and fixed_event.mask & os.linux.IN.ISDIR != 0) {
                std.log.info("Directory deleted: {s}, removing watch", .{dir_path});
                std.posix.inotify_rm_watch(inotify_fd, fixed_event.wd);
                _ = watch_map.remove(fixed_event.wd);
            }
            // Handle file events
            else if (fixed_event.mask & (os.linux.IN.CLOSE_WRITE | os.linux.IN.CREATE | os.linux.IN.MOVED_TO) != 0 and match(pattern, file_name)) {
                std.log.info("File {s} matches pattern in {s}, running command: {s}", .{ file_name, dir_path, try std.mem.join(allocator, " ", command_args) });
                var child = std.process.Child.init(command_args, allocator);
                child.cwd = dir_path; // Run command in the directory of the event
                child.stdout_behavior = .Pipe;
                child.stderr_behavior = .Pipe;

                try child.spawn();

                // Read stdout
                var stdout_buffer = std.ArrayList(u8).init(allocator);
                defer stdout_buffer.deinit();
                if (child.stdout) |stdout| {
                    try stdout_buffer.writer().writeAll(try stdout.readToEndAlloc(allocator, 1024 * 1024));
                    if (stdout_buffer.items.len > 0) {
                        std.log.info("Command stdout: {s}", .{stdout_buffer.items});
                    }
                }

                // Read stderr
                var stderr_buffer = std.ArrayList(u8).init(allocator);
                defer stderr_buffer.deinit();
                if (child.stderr) |stderr| {
                    try stderr_buffer.writer().writeAll(try stderr.readToEndAlloc(allocator, 1024 * 1024));
                    if (stderr_buffer.items.len > 0) {
                        std.log.err("Command stderr: {s}", .{stderr_buffer.items});
                    }
                }

                const term = try child.wait();
                switch (term) {
                    .Exited => |code| {
                        std.log.info("Command exited with code: {d}", .{code});
                    },
                    .Signal => |signal| {
                        std.log.info("Command terminated by signal: {d}", .{signal});
                    },
                    .Stopped => |signal| {
                        std.log.info("Command stopped by signal: {d}", .{signal});
                    },
                    .Unknown => |err| {
                        std.log.err("Command failed with unknown status: {d}", .{err});
                    },
                }
            } else {
                std.log.debug("File {s} does not match pattern {s}", .{ file_name, pattern });
            }

            offset = name_end;
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
