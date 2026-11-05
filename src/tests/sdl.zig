pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .zio, .level = .info },
    },
};

pub fn main(init: std.process.Init) !void {
    const program = blk: {
        var iter = try init.minimal.args.iterateAllocator(init.arena.allocator());
        _ = iter.skip();
        break :blk iter.next() orelse return error.NoProgamPathProvided;
    };

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        return error.SDLInitFailed;
    }

    const init_width = 512;
    const init_height = 512;

    const window = sdl.SDL_CreateWindow("agce-in-sdl", init_width, init_height, sdl.SDL_WINDOW_RESIZABLE) orelse return error.FailedToCreateWindow;
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.FailedToCreateRenderer;

    const display = display_handle_from_sdl_window(window).?;
    const window_ptr = window_handle_from_sdl_window(window).?;
    std.log.debug("Got wayland display {} surface {}", .{ display, window_ptr });

    const eh: *embeded.EmbededHandle = try .create(
        init.gpa,
        init.environ_map,
        display,
        embeded_native_from_driver(),
        "sdl_test",
    );
    defer eh.destroy();

    try eh.window_add(window_ptr, .{ .width = init_width, .height = init_height });

    const remote = try eh.remote_client_create();
    defer eh.remote_client_destroy(remote);

    var process = try eh.process_init(
        init.io,
        init.gpa,
        &.{program},
        init.environ_map,
    );
    defer process.deinit();

    try process.spawn(remote, .{
        .stderr = .ignore,
        .stdout = .ignore,
    });

    while (remote.status == .pending) {
        eh.poll();
    }

    const remote_vp = try eh.remote_viewport_embed(remote, window_ptr, .{
        .x = 100,
        .y = 100,
        .width = 250,
        .height = 250,
    });

    _ = sdl.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, 0xFF);
    _ = sdl.SDL_RenderClear(renderer);
    _ = sdl.SDL_RenderPresent(renderer);

    while (true) {
        var event: sdl.SDL_Event = undefined;
        if (sdl.SDL_WaitEvent(&event)) {
            if (handle_event(event, eh, remote_vp) == .exit) break;

            while (sdl.SDL_PollEvent(&event)) {
                if (handle_event(event, eh, remote_vp) == .exit) break;
            }
        }

        eh.poll();

        _ = sdl.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, 0xFF);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderPresent(renderer);
    }

    std.log.info("Exiting...", .{});
}

const HandleEvent = enum { exit, run };
fn handle_event(
    event: sdl.SDL_Event,
    eh: *embeded.EmbededHandle,
    remote_vp: *embeded.RemoteViewportHandle,
) HandleEvent {
    if (event.type == sdl.SDL_EVENT_QUIT) {
        return .exit;
    }

    switch (event.type) {
        sdl.SDL_EVENT_QUIT,
        sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
        => return .exit,

        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (event.button.clicks > 1) {
                remote_vp.pos_set(.{
                    .x = @trunc(event.button.x),
                    .y = @trunc(event.button.y),
                }) catch return .exit;
            }
        },
        sdl.SDL_EVENT_WINDOW_RESIZED => {
            const width = event.window.data1;
            const height = event.window.data2;

            remote_vp.size_set(.{
                .width = @divFloor(width, 3) * 2,
                .height = @divFloor(height, 3) * 2,
            }) catch return .exit;

            const window = sdl.SDL_GetWindowFromID(event.window.windowID) orelse return .exit;
            const ptr = window_handle_from_sdl_window(window).?;
            eh.window_update_size(ptr, .{ .width = width, .height = height });
        },
        else => {},
    }

    return .run;
}

fn window_handle_from_sdl_window(window: *sdl.SDL_Window) ?*anyopaque {
    const pid = sdl.SDL_GetWindowProperties(window);

    const pointer_name = switch (embeded_native_from_driver()) {
        .wayland_display => sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER,
        .win32_instance => sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER,
    };
    const ptr = sdl.SDL_GetPointerProperty(pid, pointer_name, null) orelse
        return null;

    return ptr;
}

fn display_handle_from_sdl_window(window: *sdl.SDL_Window) ?*anyopaque {
    const pid = sdl.SDL_GetWindowProperties(window);

    const pointer_name = switch (embeded_native_from_driver()) {
        .wayland_display => sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER,
        .win32_instance => sdl.SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER,
    };

    const ptr = sdl.SDL_GetPointerProperty(pid, pointer_name, null) orelse
        return null;

    return ptr;
}

fn embeded_native_from_driver() embeded.Native {
    const driver_name = sdl.SDL_GetCurrentVideoDriver();
    const driver = driver_name[0..std.mem.len(driver_name)];
    if (std.mem.eql(u8, driver, "wayland"))
        return .wayland_display
    else if (std.mem.eql(u8, driver, "windows"))
        return .win32_instance
    else
        @panic("Unknown driver");
}

const std = @import("std");
const sdl = @import("sdl");
const embeded = @import("embeded");
