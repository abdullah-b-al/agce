pub fn main(init: std.process.Init) !void {
    const program = blk: {
        var iter = try init.minimal.args.iterateAllocator(init.arena.allocator());
        _ = iter.skip();
        break :blk iter.next() orelse return error.NoProgamPathProvided;
    };

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        return error.SDLInitFailed;
    }

    const window = sdl.SDL_CreateWindow("agce-in-sdl", 512, 512, 0) orelse return error.FailedToCreateWindow;
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.FailedToCreateRenderer;

    const pid = sdl.SDL_GetWindowProperties(window);
    const display = sdl.SDL_GetPointerProperty(pid, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null) orelse return error.NoWaylandDisplayPointer;
    const surface = sdl.SDL_GetPointerProperty(pid, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) orelse return error.NoWaylandSurfacePointer;
    std.log.debug("Got wayland display {} surface {}", .{ display, surface });

    const eh: *embeded.EmbededHandle = try .create(
        init.gpa,
        init.environ_map,
        display,
        .wayland_display,
        "sdl_test",
    );
    defer eh.destroy();

    try eh.window_add(surface, .{ .width = 512, .height = 512 });

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
        .stderr = .inherit,
        .stdout = .inherit,
    });

    while (remote.status == .pending) {
        eh.poll();
    }

    const remote_vp = try eh.remote_viewport_embed(remote, surface, .{
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
            if (handle_event(event, remote_vp) == .exit) return;

            while (sdl.SDL_PollEvent(&event)) {
                if (handle_event(event, remote_vp) == .exit) return;
            }
        }

        eh.poll();

        _ = sdl.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, 0xFF);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderPresent(renderer);
    }
}

const HandleEvent = enum { exit, run };
fn handle_event(event: sdl.SDL_Event, remote_vp: *embeded.RemoteViewportHandle) HandleEvent {
    if (event.type == sdl.SDL_EVENT_QUIT) {
        return .exit;
    }

    if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN) {
        remote_vp.send_close() catch return .exit;
    }

    return .run;
}

const std = @import("std");
const sdl = @import("sdl");
const embeded = @import("embeded");
