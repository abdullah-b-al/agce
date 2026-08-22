// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "DVUI App Example - agce",
            .window_init_options = .{
                // Could set a default theme here
                // .theme = dvui.Theme.builtin.dracula,
            },
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

////////////////////////////////////////////////////////////////////////////////
// globals

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;
var handle: *agce.ClientHandle = undefined;
var viewport: *agce.ViewportHandle = undefined;

var doom_process: ?std.process.Child = null;
var doom_sub_viewport: ?*agce.SubViewportHandle = null;

var orig_content_scale: f32 = 1.0;

// globals
////////////////////////////////////////////////////////////////////////////////

// Runs before the first frame, after backend and dvui.Window.init()
// - runs between win.begin()/win.end()
pub fn appInit(win: *dvui.Window) !void {
    io = dvui.App.main_init.?.io;
    gpa = dvui.App.main_init.?.gpa;
    handle = win.backend.impl.handle;
    viewport = win.backend.impl.viewport;

    orig_content_scale = win.content_scale;

    win.themeSet(dvui.Theme.builtin.adwaita_dark);
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(_: *dvui.Window) void {}

// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    {
        var scaler = dvui.scale(@src(), .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global }, .{ .rect = .cast(dvui.windowRect()) });
        scaler.deinit();

        if (menu()) |res| return res;

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
        defer scroll.deinit();

        if (content()) |res| return res;
    }

    return .ok;
}

pub fn menu() ?dvui.App.Result {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .window, .background = true, .expand = .horizontal });
    defer hbox.deinit();

    var m = dvui.menu(@src(), .horizontal, .{});
    defer m.deinit();

    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{ .tag = "first-focusable" })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Close Menu", .{}, .{ .expand = .horizontal }) != null) {
            m.close();
        }

        if (dvui.backend.kind != .web) {
            if (dvui.menuItemLabel(@src(), "Exit", .{}, .{ .expand = .horizontal }) != null) {
                return .close;
            }
        }
    }

    return null;
}

pub fn content() ?dvui.App.Result {
    if (doom_process == null) {
        doom();
    } else if (doom_sub_viewport) |svp| {
        dvui.label(@src(), "Playing DOOM", .{}, .{});
        const box = dvui.box(@src(), .{}, .{
            .expand = .both,
        });
        defer box.deinit();

        const doom_box = dvui.flexbox(
            @src(),
            .{ .justify_content = .center },
            .{
                .expand = .both,
                .min_size_content = .{ .w = 500, .h = 500 },
                .max_size_content = .{ .w = 500, .h = 500 },
            },
        );
        defer doom_box.deinit();

        svp.rect_set(.{
            .x = @intFromFloat(box.data().contentRectScale().r.x),
            .y = @intFromFloat(box.data().contentRectScale().r.y),
            .width = @intFromFloat(box.data().rect.w),
            .height = @intFromFloat(box.data().rect.h),
        }) catch return .close;
    } else {
        var iter = handle.client_info_iterator();
        while (iter.next()) |value| {
            const name = value.info.name;
            if (std.mem.eql(u8, name, "doomgeneric")) {
                doom_sub_viewport = viewport.sub_viewport_embed(
                    value.client_id,
                    .{
                        .x = 50,
                        .y = 50,
                        .width = 500,
                        .height = 500,
                    },
                ) catch return .close;
            }
        }
    }
    return null;
}

pub fn doom() void {
    std.debug.assert(doom_process == null);
    const static = struct {
        var path_exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var path_wad_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var err: ?anyerror = null;
    };

    if (static.err) |err| {
        dvui.label(@src(), "{}", .{err}, .{ .color_text = .red });
    }

    var path_exe_buffer_len: usize = 0;
    var path_wad_buffer_len: usize = 0;

    var path_exe = dvui.textEntry(@src(), .{
        .placeholder = "Path to agce's doom port executable",
        .text = .{ .buffer = &static.path_exe_buffer },
    }, .{
        .expand = .horizontal,
    });
    path_exe_buffer_len = path_exe.len;
    path_exe.deinit();

    var path_wad = dvui.textEntry(@src(), .{
        .placeholder = "Path to WAD file",
        .text = .{ .buffer = &static.path_wad_buffer },
    }, .{
        .expand = .horizontal,
    });
    path_wad_buffer_len = path_wad.len;
    path_wad.deinit();

    if (dvui.button(@src(), "Launch DOOM", .{}, .{})) {
        static.err = null;
        if (path_exe_buffer_len > 0 and path_wad_buffer_len > 0) {
            const exe = static.path_exe_buffer[0..path_exe_buffer_len];
            const wad = static.path_wad_buffer[0..path_wad_buffer_len];

            doom_process = handle.spawn_process_to_embed(&.{
                exe, "-iwad", wad,
            }) catch |err| {
                static.err = err;
                return;
            };
        }
    }
}

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const agce = @import("agce");
