const std = @import("std");
const os = std.os;
const dict = std.hash_map;

const warn = std.debug.warn;
const assert = std.debug.assert;

const inotify_bridge = @import("inotify_bridge.zig");

const max_tracked_items = u32;
const inotify_watch_flags = os.IN_CLOSE_WRITE;

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
    var arena = std.heap.ArenaAllocator.init(&direct_allocator.allocator);
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
    const commands = argv[file_count..];

    var inotify = inotify_bridge.inotify.init(allocator) catch |err| return warn("Failed to initialize inotify instance: {}\n", err);

    for (files) |filename| {
        inotify.add_watch(filename, inotify_watch_flags) catch
            |err| return warn("{} while trying to follow '{}'\n", err, filename);
    }

    wait_and_react(&inotify);
}

fn filewrite(filename: []const u8) !void {
    const file = try std.fs.File.openWrite(filename);
    defer file.close();
    try file.write("testydoodle\n");
}

fn wait_and_react(inotify: *inotify_bridge.inotify) void {
    filewrite("test/test2.txt"[0..]) catch |err| warn("{}\n", err);
    filewrite("test/12345678910.txt"[0..]) catch |err| warn("{}\n", err);
    filewrite("test/t.txt"[0..]) catch |err| warn("{}\n", err);
    while (true) {
        const event: *inotify_bridge.inotify_event = inotify.next_event();
        assert(event == &inotify.event);
        if (valid_event(event)) {
            warn("{}\n", event);
            if (event.name) |filename| {} else {}
        }
        os.exit(1);
    }
}

fn valid_event(event: *inotify_bridge.inotify_event) bool {
    const counter = struct {
        var count: u8 = 0;
    };
    const close_write = event.mask & os.linux.IN_CLOSE_WRITE;
    const deleted = event.mask & os.linux.IN_IGNORED;
    if (close_write == 0 or deleted != 0) return false; // return error.UnexepectedEvent
    counter.count += 1;
    const dir = (event.len != 0);
    return true;
}

fn enumerate_files(argv: [][]u8) InputError!max_tracked_items {
    var stat: os.Stat = undefined;
    for (argv) |filename, index| {
        const failure = (os.system.stat(filename.ptr, &stat) != 0);
        if (failure) {
            // If we have "failure" it means we've reached an argument that we can't "stat".
            // So there would be no point in the following S_ISFILE functions.
        } else if (os.system.S_ISREG(stat.mode)) {
            continue;
        } else if (os.system.S_ISDIR(stat.mode)) {
            continue;
        }
        // Alternative form. Less easily extensible, more or less readable?
        //if (!failure and (os.system.S_ISREG(stat.mode) or os.system.S_ISDIR(stat.mode))) continue;

        // At this point we have reached an argument that is
        // either not a file or not a dir.
        if (index >= std.math.maxInt(max_tracked_items)) {
            return error.TooManyTrackedFiles;
        }
        if (index == 0) {
            return error.NoFilesFound;
        }
        return @intCast(max_tracked_items, index);
    }
    return error.NoArgumentsGiven;
}

fn concat_args(allocator: *std.mem.Allocator) ![][]u8 {
    const arg_count = os.argv.len;
    // alloc returns a "list" of type, capable of holding x many of them
    // so typeOf(alloc(i32, 10)[2]) == *i32
    const list_of_strings = try allocator.alloc([]u8, arg_count - 1);

    for (os.argv[1..arg_count]) |i, n| {
        list_of_strings[n] = std.mem.toSlice(u8, i);
    }
    return list_of_strings;
}

fn concat_args_old(allocator: *std.mem.Allocator) ![][]u8 {
    var args = std.process.args();
    const arg_count = args.inner.count;
    const list_of_strings = try allocator.alloc([]u8, arg_count - 1);

    _ = args.inner.skip();
    while (args.nextPosix()) |arg| {
        const string = try allocator.alloc(u8, arg.len);
        std.mem.copy(u8, string, arg);
        // Removing two from index because args[0] == index 1 and because we are ignoring arg[0]
        list_of_strings[args.inner.index - 2] = string;
    }
    return list_of_strings;
}
