const Process = @This();

io: Io,
gpa: std.mem.Allocator,
deinited: bool,
argv: []const []const u8,
environ: std.process.Environ.Map,

child: ?std.process.Child,
err: ?std.process.SpawnError,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    argv_to_dupe: []const []const u8,
    environ_to_clone: *const std.process.Environ.Map,
    sockt_path: ?[]const u8,
) !Process {
    var argv = try gpa.dupe([]const u8, argv_to_dupe);
    for (0..argv.len) |i| {
        argv[i] = try gpa.dupe(u8, argv_to_dupe[i]);
    }

    var environ = try environ_to_clone.clone(gpa);
    _ = environ.swapRemove(constants.env_client_uuid);

    if (sockt_path) |path| {
        try environ.put(constants.env_agce_socket_path, path);
    }

    return .{
        .io = io,
        .gpa = gpa,
        .deinited = false,
        .argv = argv,
        .child = null,
        .environ = environ,
        .err = null,
    };
}

pub fn deinit(process: *Process) void {
    if (process.child) |*child| {
        child.kill(process.io);
    }

    if (!process.deinited) {
        process.environ.deinit();

        for (process.argv) |arg| {
            process.gpa.free(arg);
        }

        process.gpa.free(process.argv);
    }

    process.deinited = true;
}

pub fn spawn(
    process: *Process,
    remote: *RemoteClient,
    options: SpawnOptions,
) !void {
    std.debug.assert(process.child == null);
    std.debug.assert(remote.status == .pending);

    std.debug.assert(!process.environ.contains(constants.env_client_uuid));

    const string = remote.uuid.serialize();
    try process.environ.put(constants.env_client_uuid, &string);

    process.child = try std.process.spawn(process.io, .{
        .argv = process.argv,
        .environ_map = &process.environ,
        .stdout = options.stdout,
        .stderr = options.stderr,
        .stdin = options.stdin,
    });
}

pub fn kill(process: *Process) void {
    if (process.child) |*child| {
        child.kill(process.io);
        process.child = null;
    }
}

pub fn wait(process: *Process) std.process.Child.WaitError!std.process.Child.Term {
    std.debug.assert(process.child != null);
    const result = process.child.?.wait(process.io);

    process.child = null;

    return result;
}

pub const SpawnOptions = struct {
    stdout: std.process.SpawnOptions.StdIo = .ignore,
    stderr: std.process.SpawnOptions.StdIo = .ignore,
    stdin: std.process.SpawnOptions.StdIo = .ignore,
};

const std = @import("std");
const Io = std.Io;
const constants = @import("constants");
const ptypes = @import("protocol").types;
const RemoteClient = @import("RemoteClient.zig");
