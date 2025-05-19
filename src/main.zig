const std = @import("std");
const os = std.os;
const mem = std.mem;

const bb = @import("root.zig");

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
    const path = try bb.getAbsoluteDirPath(allocator, input_path);
    std.log.info("Monitoring directory: {s}, pattern: {s}, command: {s}", .{ path, pattern, command_args[0] });

    // Initialize inotify
    const inotify_fd = try std.posix.inotify_init1(0);
    defer std.posix.close(inotify_fd);

    // Map watch descriptors to directory paths
    var watch_map = std.AutoHashMap(i32, []u8).init(allocator);
    defer watch_map.deinit();

    // Map directories to .gitignore patterns
    var ignore_map = std.StringHashMap(bb.IgnorePatterns).init(allocator);
    defer {
        var it = ignore_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            allocator.free(entry.key_ptr.*);
        }
        ignore_map.deinit();
    }

    // Recursively add watches for the directory and its subdirectories
    try bb.addRecursiveWatches(allocator, inotify_fd, path, &watch_map, &ignore_map, os.linux.IN.CLOSE_WRITE | os.linux.IN.CREATE | os.linux.IN.MOVED_TO | os.linux.IN.DELETE);

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
                try bb.addRecursiveWatches(allocator, inotify_fd, new_dir_path, &watch_map, &ignore_map, os.linux.IN.CLOSE_WRITE | os.linux.IN.CREATE | os.linux.IN.MOVED_TO | os.linux.IN.DELETE);
            }
            // Handle directory deletion
            else if (fixed_event.mask & os.linux.IN.DELETE != 0 and fixed_event.mask & os.linux.IN.ISDIR != 0) {
                std.log.info("Directory deleted: {s}, removing watch", .{dir_path});
                std.posix.inotify_rm_watch(inotify_fd, fixed_event.wd);
                _ = watch_map.remove(fixed_event.wd);
            }
            // Handle file events
            else if (fixed_event.mask & (os.linux.IN.CLOSE_WRITE | os.linux.IN.CREATE | os.linux.IN.MOVED_TO) != 0 and bb.match(pattern, file_name, false)) {
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
                        std.debug.print("\n========== stdout ===========\n{s}\n===========================\n", .{stdout_buffer.items});
                    }
                }

                // Read stderr
                var stderr_buffer = std.ArrayList(u8).init(allocator);
                defer stderr_buffer.deinit();
                if (child.stderr) |stderr| {
                    try stderr_buffer.writer().writeAll(try stderr.readToEndAlloc(allocator, 1024 * 1024));
                    if (stderr_buffer.items.len > 0) {
                        std.debug.print("\n========== stderr ===========\n{s}\n===========================\n", .{stderr_buffer.items});
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
