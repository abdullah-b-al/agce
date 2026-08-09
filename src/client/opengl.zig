pub const ContextLinux = struct {
    egl_display: *anyopaque,
    egl_context: *anyopaque,
};

pub fn init_linux(gbm_device: *c_linux.struct_gbm_device, major: c_int, minor: c_int) !ContextLinux {
    const display =
        c_linux.eglGetPlatformDisplay(c_linux.EGL_PLATFORM_GBM_KHR, gbm_device, null) orelse
        return error.CouldNotGetPlatformDisplay;

    if (c_linux.eglInitialize(display, null, null) == c_linux.EGL_FALSE) {
        std.log.err("Failed to eglInitialize", .{});
        return error.FailedToEglInitialize;
    }
    std.log.info("eglInitialize success {}", .{c_linux.eglGetError() == c_linux.EGL_SUCCESS});

    if (c_linux.eglBindAPI(c_linux.EGL_OPENGL_API) == c_linux.EGL_FALSE) {
        return error.FailedToEglBindAPI;
    }
    std.log.info("eglBindAPI success {}", .{c_linux.eglGetError() == c_linux.EGL_SUCCESS});

    const config_attribs: []const c_linux.EGLint = &.{
        c_linux.EGL_RENDERABLE_TYPE,
        c_linux.EGL_OPENGL_BIT,
        c_linux.EGL_NONE,
    };

    var egl_config: c_linux.EGLConfig = undefined;
    var num_config: c_linux.EGLint = undefined;

    if (c_linux.eglChooseConfig(display, config_attribs.ptr, &egl_config, 1, &num_config) ==
        c_linux.EGL_FALSE)
    {
        return error.FailedToEglChooseConfig;
    }

    if (num_config == 0) {
        return error.FailedToEglChooseConfig;
    }

    std.log.info("eglChooseConfig success {} num_config {}", .{
        c_linux.eglGetError() == c_linux.EGL_SUCCESS,
        num_config,
    });

    std.log.info("Vendor      : {s}", .{c_linux.eglQueryString(display, c_linux.EGL_VENDOR)});
    std.log.info("Version     : {s}", .{c_linux.eglQueryString(display, c_linux.EGL_VERSION)});
    std.log.info("Client APIs : {s}", .{c_linux.eglQueryString(display, c_linux.EGL_CLIENT_APIS)});
    std.log.info("Extensions  : {s}", .{c_linux.eglQueryString(display, c_linux.EGL_EXTENSIONS)});

    const context_attribs: []const c_linux.EGLint = &.{
        c_linux.EGL_CONTEXT_MAJOR_VERSION,
        major,
        c_linux.EGL_CONTEXT_MINOR_VERSION,
        minor,
        c_linux.EGL_NONE,
    };

    const context = c_linux.eglCreateContext(
        display,
        egl_config,
        c_linux.EGL_NO_CONTEXT,
        context_attribs.ptr,
    ) orelse {
        const err = egl_get_error_context();
        std.log.err("{} {s}", .{ err.num, err.string });
        return error.FailedToEglCreateContext;
    };
    std.log.info("eglCreateContext {s}", .{egl_get_error_context().string});

    _ = c_linux.eglMakeCurrent(display, c_linux.EGL_NO_SURFACE, c_linux.EGL_NO_SURFACE, context);
    if (c_linux.eglGetError() != c_linux.EGL_SUCCESS) {
        return error.FailedToEglMakeCurrent;
    }

    return .{
        .egl_display = display,
        .egl_context = context,
    };
}

pub fn get_proc_address(procname: [*c]const u8) callconv(.c) c_linux.__eglMustCastToProperFunctionPointerType {
    return c_linux.eglGetProcAddress(procname);
}

pub fn load_gl(ctx: ContextLinux) !void {
    if (glad.gladLoadEGL(ctx.egl_display, get_proc_address) == 0) {
        return error.FailedToGladLoadEGL;
    }

    if (glad.gladLoadGLES2(get_proc_address) == 0) {
        return error.FailedToGladLoadGLES2;
    }
}

pub const GbmBackedTexture = struct {
    texture: glad.GLuint,
    image: EGLImageKHR,

    pub const EGLImageKHR = *anyopaque;
};

pub fn egl_image_from_gbm_bo(ctx: ContextLinux, bo: *c_linux.struct_gbm_bo) !GbmBackedTexture {
    var texture: glad.GLuint = 0;
    glad.glGenTextures(1, &texture);
    glad.glBindTexture(glad.GL_TEXTURE_2D, texture);

    const image = glad.eglCreateImageKHR(
        ctx.egl_display,
        ctx.egl_context,
        glad.EGL_NATIVE_PIXMAP_KHR,
        bo,
        null,
    ) orelse return error.eglCreateImageKHR;

    glad.glEGLImageTargetTexture2DOES(glad.GL_TEXTURE_2D, image);

    return .{ .image = image, .texture = texture };
}

pub fn fbo_gen(texture: glad.GLuint) !glad.GLuint {
    var fbo: glad.GLuint = undefined;
    glad.glGenFramebuffers(1, &fbo);
    glad.glBindFramebuffer(glad.GL_FRAMEBUFFER, fbo);

    glad.glFramebufferTexture2D(
        glad.GL_FRAMEBUFFER,
        glad.GL_COLOR_ATTACHMENT0,
        glad.GL_TEXTURE_2D,
        texture,
        0,
    );

    const fbo_error = glad.glGetError();
    if (fbo_error != glad.GL_NO_ERROR) {
        return error.FailedToGenFbo;
    }
    //
    const status = glad.glCheckFramebufferStatus(glad.GL_FRAMEBUFFER);
    if (status != glad.GL_FRAMEBUFFER_COMPLETE) {
        return error.GlFrameBufferIncomplete;
    }

    return fbo;
}

fn egl_get_error_context() struct { num: i32, string: []const u8 } {
    const err = c_linux.eglGetError();
    const string = switch (err) {
        c_linux.EGL_SUCCESS => "EGL_SUCCESS",
        c_linux.EGL_NOT_INITIALIZED => "EGL_NOT_INITIALIZED",
        c_linux.EGL_BAD_ACCESS => "EGL_BAD_ACCESS",
        c_linux.EGL_BAD_ALLOC => "EGL_BAD_ALLOC",
        c_linux.EGL_BAD_ATTRIBUTE => "EGL_BAD_ATTRIBUTE",
        c_linux.EGL_BAD_CONTEXT => "EGL_BAD_CONTEXT",
        c_linux.EGL_BAD_CONFIG => "EGL_BAD_CONFIG",
        c_linux.EGL_BAD_CURRENT_SURFACE => "EGL_BAD_CURRENT_SURFACE",
        c_linux.EGL_BAD_DISPLAY => "EGL_BAD_DISPLAY",
        c_linux.EGL_BAD_SURFACE => "EGL_BAD_SURFACE",
        c_linux.EGL_BAD_MATCH => "EGL_BAD_MATCH",
        c_linux.EGL_BAD_PARAMETER => "EGL_BAD_PARAMETER",
        c_linux.EGL_BAD_NATIVE_PIXMAP => "EGL_BAD_NATIVE_PIXMAP",
        c_linux.EGL_BAD_NATIVE_WINDOW => "EGL_BAD_NATIVE_WINDOW",
        c_linux.EGL_CONTEXT_LOST => "EGL_CONTEXT_LOST",
        else => "Unknown Error",
    };

    return .{ .num = err, .string = string };
}

const std = @import("std");
const Io = std.Io;
const c_linux = @import("c_linux");
const glad = @import("glad");
