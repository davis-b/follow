// These custom events have an extra field
// event.tracked_item_name
// Which would be a hashmap or simple list under the hood,
// matching WDs of tracked items to names given.

// could have one thread collecting events and adding them to a uueue
// and whatever code interfaces with this library could simply pull from
// the queue.

// Should we return a new inotify_event struct for each event,
// or reuse the same one?
// Let's just reuse the same one. If require new structs for each
// event, they can use the function "read_event".

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

const extra_inotify_event = struct {
    event: inotify_event,
    full_path_name: []u8,
};

// Buffer must be evenly divisble by the alignment of inotify_event
// for when we @alignCast a buffer.ptr later on.
fn find_buffer_length() comptime_int {
    var i_buffer_length: comptime_int = os.PATH_MAX + @sizeOf(std_inotify_event) + 1;
    while (i_buffer_length % @alignOf(std_inotify_event) != 0) {
        i_buffer_length += 1;
    }
    return i_buffer_length;
}
//pub const buffer_length = find_buffer_length();
pub const buffer_length = 40960;

const temp_holder = struct {
    var ptr: [*]u8 = undefined;
    var ptr_end: [*]u8 = undefined;
    var event_number: u32 = 0;
    var first: bool = true;
};

pub const inotify = struct {
    const Self = @This();
    event_buffer: [buffer_length]u8 = undefined,
    event: inotify_event = undefined,
    //   allocator: *Allocator,
    inotify_fd: i32,
    hashmap: hashmap_type,

    pub fn init(allocator: *mem.Allocator) !inotify {
        return inotify{
            //          .allocator = allocator,
            .inotify_fd = try os.inotify_init1(0),
            .hashmap = hashmap_type.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // allocator.destroy
        self.hashmap.deinit();
        //self.event_buffer = undefined;
        //self.remove_watch();
    }

    pub fn add_watch(self: *Self, filename: []u8, flags: u32) !void {
        const watchid: i32 = try os.inotify_add_watch(self.inotify_fd, filename, flags);
        _ = try self.hashmap.put(watchid, filename);
    }

    pub fn remove_watch(self: *Self, watch_descriptor: i32) ?self.hashmap.KV {
        os.inotify_rm_watch(self.inotify_fd, watch_descriptor);
        return self.hashmap.remove(watch_descriptor);
    }

    // These three functions serve the same purpose

    pub fn next_event_unnecessary(self: *Self) *inotify_event {
        if (temp_holder.first) {
            temp_holder.ptr = self.event_buffer[0..].ptr;
            temp_holder.ptr_end = temp_holder.ptr + self.event_buffer.len;
            temp_holder.first = false;
        }
        // is this necessary?
        if ((@ptrToInt(temp_holder.ptr) < @ptrToInt(temp_holder.ptr_end)) and temp_holder.event_number > 0) {
            std.debug.warn("x\n");
            temp_holder.ptr += @sizeOf(inotify_event);
            read_event(temp_holder.ptr, &self.event);
            return &self.event;
        }
        temp_holder.ptr = &self.event_buffer;
        temp_holder.event_number += 1;
        const read_result = os.linux.read(self.inotify_fd, &self.event_buffer, self.event_buffer.len);
        read_event(&self.event_buffer, &self.event);
        return &self.event;
    }

    pub fn next_event(self: *Self) *inotify_event {
        // todo: add attribute to event, watched_name
        const read_result = os.linux.read(self.inotify_fd, &self.event_buffer, self.event_buffer.len);
        read_event(&self.event_buffer, &self.event);
        //self.event.watched_name = self.hashmap.getValue orelse unreachable;
        return &self.event;
    }

    pub fn read_events(self: *Self) void {
        // todo: make async, suspend/resume
        var ptr = self.event_buffer[0..].ptr;
        const end_ptr = self.event_buffer.len;
        while (true) : (ptr = event_buffer[0..].ptr) {
            // const read_result = os.read(inotify_fd, event_buffer[0..]);
            const read_result = os.linux.read(inotify_fd, &event_buffer, event_buffer.len);
            //while (@ptrToInt(ptr) < @ptrToInt(end_ptr)) : (ptr += @sizeOf(inotify_event)) {
            while (@ptrToInt(ptr) < @ptrToInt(end_ptr)) : (ptr += @sizeOf(std_inotify_event) + event.len) {
                const event = @ptrCast(*std_inoitfy_event, ptr);
                const custom_event: inotify_event = undefined;
                read_event(ptr, &custom_event);
                return custom_event;
            }
        }
    }
};

// *****************************************************************

const event_temp = struct {
    var data: *std_inotify_event = undefined;
};

pub fn read_event(bufferptr: [*]u8, event: *inotify_event) void {
    var ptr = @alignCast(@alignOf(std_inotify_event), bufferptr);
    event_temp.data = @ptrCast(*std_inotify_event, ptr);
    var name = @ptrCast([*]u8, &event_temp.data.nameaddr);
    const namelen = mem.len(u8, name);

    event.wd = event_temp.data.wd;
    event.mask = event_temp.data.mask;
    event.cookie = event_temp.data.cookie;
    event.len = event_temp.data.len;
    //event.name = name[0..namelen];
    event.name = if (event.len != 0) name[0..namelen] else null;
}

// *****************************************************************
