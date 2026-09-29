pub const Win32EventHandle = @This();

handle: if (os == .windows) *anyopaque else void,

pub fn create(socket: zio.net.Socket, comptime kind: enum { client, accept }) error{FailedToCreateWin32EventHandle}!Win32EventHandle {
    const handle = switch (os) {
        .windows => blk: {
            const event = win_sock.WSACreateEvent() orelse return error.FailedToCreateWin32EventHandle;

            const events: i32 = switch (kind) {
                .client => win_sock.FD_READ | win_sock.FD_CLOSE,
                .accept => win_sock.FD_ACCEPT,
            };
            if (win_sock.WSAEventSelect(
                @ptrCast(socket.handle),
                event,
                events,
            ) != 0) {
                return error.FailedToCreateWin32EventHandle;
            }
            break :blk event;
        },
        else => {},
    };

    return .{ .handle = handle };
}

pub fn close(event: *Win32EventHandle) void {
    if (os == .windows) {
        _ = win_sock.WSACloseEvent(event.handle);
    }
}

const std = @import("std");
const os = @import("builtin").os.tag;
const zio = @import("zio");
const win_sock = @import("win32").networking.win_sock;
