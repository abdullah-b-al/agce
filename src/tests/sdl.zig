pub fn main(init: std.process.Init) !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        return error.SDLInitFailed;
    }

    const window = sdl.SDL_CreateWindow("agce-in-sdl", 512, 512, 0) orelse return error.FailedToCreateWindow;
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.FailedToCreateRenderer;

    const pid = sdl.SDL_GetWindowProperties(window);
    const display = sdl.SDL_GetPointerProperty(pid, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null) orelse return error.NoWaylandDisplayPointer;
    const surface = sdl.SDL_GetPointerProperty(pid, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) orelse return error.NoWaylandSurfacePointer;
    std.debug.print("Got wayland display {} surface {}\n", .{ display, surface });

    const em: *embeded.Embeded = try .create(
        init.gpa,
        init.environ_map,
        display,
        .wayland_display,
        "sdl_test",
    );
    defer em.destroy();

    while (true) {
        var has_event = false;
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            if (event.type == sdl.SDL_EVENT_QUIT) {
                return;
            }

            has_event = true;
        }

        if (has_event) {
            std.debug.print("Recevied event from sdl\n", .{});
        }

        _ = sdl.SDL_SetRenderDrawColor(renderer, 0xFF, 0xFF, 0xFF, 0xFF);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderPresent(renderer);
    }
}

const std = @import("std");
const sdl = @import("sdl");
const embeded = @import("embeded");
