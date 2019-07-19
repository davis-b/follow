// #inotify_bridge.zig
// Handles some of the more general inotify use cases

const std = @import("std");
const os = std.os;
const mem = std.mem;

const hashmap_type = std.hash_map.AutoHashMap(i32, []u8);

comptime {
    if (!os.linux.is_the_target) {
        @compileError("Unsupported OS");
    }
}

const std_inotify_event = extern struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    len: u32,
    nameaddr: ?[*]u8,
};

pub const inotify_event = struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    len: u32,
    name: ?[]u8,
};

pub const expanded_inotify_event = struct {
    event: *inotify_event,
    watched_name: []u8,
};

// Buffer must be evenly divisble by the alignment of inotify_event
// for when we @alignCast a buffer ptr later on.
fn find_buffer_length() comptime_int {
    var i_buffer_length: comptime_int = os.PATH_MAX + @sizeOf(std_inotify_event) + 1;
    while (i_buffer_length % @alignOf(std_inotify_event) != 0) {
        i_buffer_length += 1;
    }
    return i_buffer_length;
}
pub const buffer_length = find_buffer_length();

pub const inotify = struct {
    const Self = @This();
    event_buffer: [buffer_length]u8 = undefined,
    event: inotify_event = undefined,
    expanded_event: expanded_inotify_event = undefined,
    inotify_fd: i32,
    hashmap: hashmap_type,

    pub fn init(allocator: *mem.Allocator) !inotify {
        return inotify{
            .inotify_fd = try os.inotify_init1(0),
            .hashmap = hashmap_type.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.hashmap.deinit();
        // TODO //self.remove_watch(); for each watched item
    }

    pub fn add_watch(self: *Self, filename: []u8, flags: u32) !void {
        const watchid: i32 = try os.inotify_add_watch(self.inotify_fd, filename, flags);
        _ = try self.hashmap.put(watchid, filename);
    }

    pub fn remove_watch(self: *Self, watch_descriptor: i32) ?hashmap_type.KV {
        os.inotify_rm_watch(self.inotify_fd, watch_descriptor);
        return self.hashmap.remove(watch_descriptor);
    }

    pub fn next_event(self: *Self) *expanded_inotify_event {
        const read_result = os.linux.read(self.inotify_fd, &self.event_buffer, self.event_buffer.len);
        read_event(&self.event_buffer, &self.event);
        self.expanded_event.event = &self.event;
        self.expanded_event.watched_name = self.hashmap.getValue(self.event.wd) orelse unreachable;
        return &self.expanded_event;
    }
};

// *****************************************************************

var event_temp: *std_inotify_event = undefined;

pub fn read_event(bufferptr: [*]u8, event: *inotify_event) void {
    var ptr = @alignCast(@alignOf(std_inotify_event), bufferptr);
    event_temp = @ptrCast(*std_inotify_event, ptr);
    var name = @ptrCast([*]u8, &event_temp.nameaddr);
    const namelen = mem.len(u8, name);

    event.wd = event_temp.wd;
    event.mask = event_temp.mask;
    event.cookie = event_temp.cookie;
    event.len = event_temp.len;
    //event.name = name[0..namelen];
    event.name = if (event.len != 0) name[0..namelen] else null;
}
