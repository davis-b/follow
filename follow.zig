// follow.zig - a program designed to watch specific files
// and execute user provided commands on writes to watched files.

//TODO:
//Add list of files to specifically ignore,
//even if found inside a watched directory.
// Allow globbing for above blacklist.

// Should we have a separate thread just for
// reading inotify events, to ensure none get skipped?

const std = @import("std");
const os = std.os;
const dict = std.hash_map;

const warn = std.debug.warn;
const assert = std.debug.assert;

const inotify_bridge = @import("inotify_bridge.zig");

const max_tracked_items = u32;
const inotify_watch_flags = os.IN_CLOSE_WRITE | os.IN_DELETE_SELF;
const filename_fill_flag = "%f";

comptime {
    if (!os.linux.is_the_target) {
        @compileError("Unsupported OS");
    }
}

fn usage() void {
    warn("Usage descriptor\n");
}

const InputError = error{
    TooManyTrackedFiles,
    NoArgumentsGiven,
    NoFilesFound,
};

pub fn main() !void {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();
    const dallocator = &direct_allocator.allocator;
    var arena = std.heap.ArenaAllocator.init(dallocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const argv: [][]u8 = try concat_args(allocator);
    const file_count: max_tracked_items = enumerate_files(argv) catch |err| {
        switch (err) {
            error.TooManyTrackedFiles => return warn("{}\n", err),
            error.NoArgumentsGiven => return warn("{}\n", err),
            error.NoFilesFound => return warn("{}\n", err),
        }
    };
    const files = argv[0..file_count];
    const user_commands = argv[file_count..];

    var inotify = inotify_bridge.inotify.init(allocator) catch
        |err| return warn("Failed to initialize inotify instance: {}\n", err);
    defer inotify.deinit();

    for (files) |filename| {
        inotify.add_watch(filename, inotify_watch_flags) catch
            |err| return warn("{} while trying to follow '{}'\n", err, filename);
    }
    const fill_flag_indexes_opt: ?[]usize = try locate_needle_indexes(
        dallocator,
        filename_fill_flag[0..],
        user_commands,
    );
    defer if (fill_flag_indexes_opt) |ff_indexes| dallocator.free(ff_indexes);

    var execve_command = [_][]const u8{
        "/bin/sh",
        "-c",
        "echo this should be replaced",
    };

    const envmap = try std.process.getEnvMap(allocator);
    var full_event: *inotify_bridge.expanded_inotify_event = undefined;

    if (fill_flag_indexes_opt) |fill_flag_indexes| {
        var filepath: []u8 = undefined;
        while (true) {
            full_event = inotify.next_event();
            const event_type: EventType = discover_event_type(full_event, &inotify);
            if (event_type == EventType.Unexpected or event_type == EventType.Deleted) continue;
            if (event_type == EventType.Replaced) rewatch_replaced_file(full_event, &inotify);
            if (full_event.event.name) |filename| {
                filepath = std.fs.path.joinPosix(dallocator, [_][]const u8{ full_event.watched_name, filename }) catch |err| {
                    warn(
                        "Encountered '{}' while allocating memory for a concatenation of '{}' and '{}'\n",
                        err,
                        full_event.watched_name,
                        filename,
                    );
                    continue;
                };
            } else {
                filepath = full_event.watched_name;
            }
            defer if (full_event.event.len != 0) dallocator.free(filepath);
            for (fill_flag_indexes) |index| {
                user_commands[index] = filepath;
            }
            const argv_commands = std.mem.join(dallocator, " ", user_commands) catch |err| {
                warn("Encountered '{}' while allocating memory for a concatenation input commands\n", err);
                continue;
            };
            defer dallocator.free(argv_commands);
            execve_command[2] = argv_commands;
            run_command(dallocator, &execve_command, &envmap) catch |err| {
                warn("Encountered '{}' while forking before running command {}\n", err, argv_commands);
                continue;
            };
        }
    } else {
        const argv_commands = try std.mem.join(allocator, " ", user_commands);
        execve_command[2] = argv_commands;
        while (true) {
            full_event = inotify.next_event();
            const event_type: EventType = discover_event_type(full_event, &inotify);
            if (event_type == EventType.Unexpected or event_type == EventType.Deleted) continue;
            if (event_type == EventType.Replaced) rewatch_replaced_file(full_event, &inotify);
            run_command(dallocator, &execve_command, &envmap) catch |err| {
                warn("Encountered '{}' while forking before running command {}\n", err, argv_commands);
                continue;
            };
        }
    }
}

fn run_command(allocator: *std.mem.Allocator, command: [][]const u8, envmap: *const std.BufMap) !void {
    const pid = try os.fork();
    if (pid == 0) {
        const err = os.execve(allocator, command, envmap);
        for (command) |cmd| warn("Error running '{}'\n", cmd);
        warn("Error : '{}'\n", err);
    } else {
        const status = os.waitpid(pid, 0);
        // while status != what we're looking for { status = waitpid }
        if (status != 0) warn("child process exited with status: {}\n", status);
    }
}

const EventType = enum {
    CloseWrite,
    Deleted,
    Replaced,
    Unexpected,
};

fn discover_event_type(
    full_event: *inotify_bridge.expanded_inotify_event,
    inotify: *inotify_bridge.inotify,
) EventType {
    const event = full_event.event;
    const close_write = event.mask & os.linux.IN_CLOSE_WRITE != 0;
    const unwatched = event.mask & os.linux.IN_IGNORED != 0;
    const deleted = event.mask & os.linux.IN_DELETE_SELF != 0;
    const any_deleted = (deleted or unwatched);

    if (any_deleted) {
        var stat: os.Stat = undefined;
        var file_exists: bool = undefined;
        if (event.name) |filename| { // file indirectly watched via watched dir
            file_exists = (os.system.stat(filename.ptr, &stat) == 0);
        } else {
            file_exists = (os.system.stat(full_event.watched_name.ptr, &stat) == 0);
        }
        if (file_exists) return EventType.Replaced;
        return EventType.Deleted;
    }
    if (close_write) return EventType.CloseWrite;
    return EventType.Unexpected;
}

fn rewatch_replaced_file(
    full_event: *inotify_bridge.expanded_inotify_event,
    inotify: *inotify_bridge.inotify,
) void {
    // Is inotify only sending deleted or unwatched, or is it sending both
    // and we're only receiving/processing one?
    // Could that be a race condition? If we receive both a deleted and unwatched
    // for a single file swap, we could end up calling "user_command" twice by accident.

    // TODO: Decide if we return true on the existence of any file, or only if a file is "trackable"?
    // is this a race condition? If a file is being replaced by, for example, a .swp file
    // Could this code be called in the middle, after deletion and before movement of .swp?
    _ = inotify.hashmap.remove(full_event.event.wd);
    if (trackable_file(full_event.watched_name)) {
        inotify.add_watch(full_event.watched_name, inotify_watch_flags) catch return;
    }
}

fn enumerate_files(argv: [][]u8) InputError!max_tracked_items {
    for (argv) |filename, index| {
        if (trackable_file(filename)) continue;

        if (index >= std.math.maxInt(max_tracked_items)) {
            return error.TooManyTrackedFiles;
        }
        if (index == 0) {
            return error.NoFilesFound;
        }
        return @intCast(max_tracked_items, index);
    } else {
        return error.NoArgumentsGiven;
    }
}

fn trackable_file(filename: []u8) bool {
    var stat: os.Stat = undefined;
    const failure = (os.system.stat(filename.ptr, &stat) != 0);
    if (failure) {
        return false;
    }
    return os.system.S_ISREG(stat.mode) or os.system.S_ISDIR(stat.mode);
}

fn concat_args(allocator: *std.mem.Allocator) ![][]u8 {
    const arg_count = os.argv.len;
    const list_of_strings = try allocator.alloc([]u8, arg_count - 1);

    for (os.argv[1..arg_count]) |i, n| {
        list_of_strings[n] = std.mem.toSlice(u8, i);
    }
    return list_of_strings;
}

fn locate_needle_indexes(allocator: *std.mem.Allocator, needle: []const u8, haystack: [][]u8) !?[]usize {
    var needle_indexes: []usize = undefined;
    needle_indexes = try allocator.alloc(usize, haystack.len);
    for (needle_indexes) |*i| i.* = 0;
    var outer_index: usize = 0;
    for (haystack) |cmd, index| {
        if (std.mem.eql(u8, cmd, needle)) {
            needle_indexes[outer_index] = index;
            outer_index += 1;
        }
    }
    // no needles in haystack
    if (outer_index == 0) {
        allocator.free(needle_indexes);
        return null;
    }
    var index_count: usize = 1;
    for (needle_indexes[1..]) |i| {
        if (i == 0) break;
        index_count += 1;
    }
    needle_indexes = allocator.shrink(needle_indexes, index_count);
    return needle_indexes;
}

fn filewrite(filename: []const u8) !void {
    const file = try std.fs.File.openWrite(filename);
    defer file.close();
    try file.write("");
}
