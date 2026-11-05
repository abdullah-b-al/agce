pub const Native = Embeded.Native;
pub const Process = @import("remote_client").Process;
pub const RemoteClient = @import("remote_client").RemoteClient;
pub const Size = ptypes.Size;
pub const Rect = ptypes.Rect;

pub const EmbededHandle = opaque {
    fn cast(h: *EmbededHandle) *Embeded {
        return @ptrCast(@alignCast(h));
    }

    pub fn create(
        gpa: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        ptr: *anyopaque,
        native: Native,
        class: []const u8,
    ) !*EmbededHandle {
        return @ptrCast(
            try Embeded.create(gpa, environ_map, ptr, native, class),
        );
    }

    pub fn destroy(h: *EmbededHandle) void {
        h.cast().destroy();
    }

    pub fn poll(h: *EmbededHandle) void {
        h.cast().poll();
    }

    pub fn window_add(h: *EmbededHandle, new: *anyopaque, size: Size) !void {
        try h.cast().window_add(new, size);
    }

    pub fn remote_client_create(h: *EmbededHandle) !*RemoteClient {
        return try h.cast().remote_client_create();
    }

    pub fn remote_client_destroy(h: *EmbededHandle, remote: *RemoteClient) void {
        h.cast().remote_client_destroy(remote);
    }

    pub fn process_init(
        h: *EmbededHandle,
        io: Io,
        gpa: std.mem.Allocator,
        argv: []const []const u8,
        environ_map: *const std.process.Environ.Map,
    ) !Process {
        return try .init(
            io,
            gpa,
            argv,
            environ_map,
            h.cast().com.socket_path(),
        );
    }

    pub fn remote_viewport_embed(
        h: *EmbededHandle,
        remote: *RemoteClient,
        window_handle: *anyopaque,
        rect: Rect,
    ) !*RemoteViewportHandle {
        return @ptrCast(
            try h.cast().remote_viewport_embed(
                remote,
                window_handle,
                rect,
            ),
        );
    }
};

pub const RemoteViewportHandle = opaque {
    fn cast(h: *RemoteViewportHandle) *RemoteViewport {
        return @ptrCast(@alignCast(h));
    }

    pub fn state(h: *RemoteViewportHandle) RemoteViewport.State {
        return h.cast().state;
    }
};

const std = @import("std");
const Io = std.Io;
const Embeded = @import("Embeded.zig");
const RemoteViewport = @import("RemoteViewport.zig");
const compositor = @import("compositor");
const zio = @import("zio");
const LocalConnection = @import("LocalConnection.zig");
const ptypes = @import("protocol").types;
