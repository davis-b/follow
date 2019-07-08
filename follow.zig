const std = @import("std");
const os = std.os;
const dict = std.hash_map;

const warn = std.debug.warn;
const assert = std.debug.assert;

const inotify_bridge = @import("inotify_bridge.zig");

const max_tracked_items = u32;
const inotify_watch_flags = os.IN_CLOSE_WRITE;
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
    const commands = argv[file_count..];

    var inotify = inotify_bridge.inotify.init(allocator) catch
        |err| return warn("Failed to initialize inotify instance: {}\n", err);
    defer inotify.deinit();

    for (files) |filename| {
        inotify.add_watch(filename, inotify_watch_flags) catch
            |err| return warn("{} while trying to follow '{}'\n", err, filename);
    }
    const filename_fill_flag_active = blk: {
        for (commands) |cmd| {
            if (std.mem.eql(u8, cmd, filename_fill_flag)) break :blk true;
        }
        break :blk false;
    };
    var envmap = std.process.getEnvMap(allocator) catch unreachable;
    defer envmap.deinit();

    //filewrite("test/test2.txt"[0..]) catch |err| warn("{}\n", err);
    filewrite("test/12345678910.txt"[0..]) catch |err| warn("{}\n", err);
    //filewrite("test.txt"[0..]) catch |err| warn("{}\n", err);

    var command: [3][]const u8 = undefined;
    command[0] = "/bin/sh";
    command[1] = "-c";
    command[2] = "echo this should be replaced";

    var full_event: *inotify_bridge.expanded_inotify_event = undefined;
    var filepath: []u8 = undefined;
    while (true) {
        full_event = inotify.next_event();
        warn("{}\n", full_event);
        if (!valid_event(full_event.event)) continue;
        if (full_event.event.name) |filename| {
            filepath = try std.fs.path.joinPosix(dallocator, [_][]const u8{ full_event.watched_name, filename });
            defer warn("can we defer to outer scope?\n");
        } else {
            filepath = full_event.watched_name;
        }
        defer if (full_event.event.len != 0) dallocator.free(filepath);

        if (filename_fill_flag_active) {
            //const filled_commands = replace(dallocator, filename_fill_flag, filepath, commands);
        }

        const argv_commands = try std.mem.join(dallocator, " ", commands);
        defer dallocator.free(argv_commands);
        // try std.mem.replace(dallocator, "filename_fill_flag", argv_commands, filepath });
        command[2] = argv_commands;
        //const acmd = try std.mem.join(dallocator, " ", [_][]const u8{ argv_commands, filepath });
        //defer dallocator.free(acmd);
        //command[2] = acmd;
        warn("running :  {}\n", command[0]);
        warn("running :  {}\n", command[1]);
        warn("running :  {}\n", command[2]);
        //try run_command(dallocator, &command, &envmap);
        break;
    }
}

fn run_command(allocator: *std.mem.Allocator, command: [][]const u8, envmap: *std.BufMap) !void {
    const pid = try os.fork();
    if (pid == 0) {
        const err = os.execve(allocator, command, envmap);
    } else {
        const status = os.waitpid(pid, 0);
        // while status != what we're looking for { status = waitpid }
        warn("child exited with status: {}\n", status);
    }
}

fn filewrite(filename: []const u8) !void {
    const file = try std.fs.File.openWrite(filename);
    defer file.close();
    try file.write("testydoodle\n");
}

fn replace(allocator: *std.mem.Allocator, replacee: []u8, replacement: []u8, original: []u8) void {
    // do we want to modify the original or return a new copy?
    // if we modify the original, we would need to make note of the indexes of each flag
    for (argv) |index, word| {
        if (std.mem.eql(u8, word, file_flag)) {
            warn("replace this: {}\n", word);
            // argv[index] = filename;
        }
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
    } else {
        return error.NoArgumentsGiven;
    }
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
