const Process = @This();

io: Io,
arena: std.heap.ArenaAllocator,
deinited: bool,
argv: []const []const u8,
environ: std.process.Environ.Map,

uuid: ptypes.ClientUUID,
child: ?std.process.Child,
err: ?std.process.SpawnError,
status: Status,

pub fn create(
    io: Io,
    gpa: std.mem.Allocator,
    argv_to_dupe: []const []const u8,
    environ_to_clone: *const std.process.Environ.Map,
) !*Process {
    const process = try gpa.create(Process);
    errdefer gpa.destroy(process);

    process.arena = .init(gpa);
    errdefer process.arena.deinit();
    const arena = process.arena.allocator();

    const environ = try environ_to_clone.clone(arena);
    var argv = try arena.dupe([]const u8, argv_to_dupe);
    for (0..argv.len) |i| {
        argv[i] = try arena.dupe(u8, argv_to_dupe[i]);
    }

    process.* = .{
        .io = io,
        .arena = process.arena,
        .deinited = false,
        .argv = argv,
        .uuid = .new(io),
        .child = null,
        .environ = environ,
        .err = null,
        .status = .pending,
    };

    return process;
}

pub fn deinit(process: *Process) void {
    if (process.child) |*child| {
        child.kill(process.io);
    }

    if (!process.deinited) {
        process.arena.deinit();
    }

    process.deinited = true;
}

pub fn spawn(
    process: *Process,
    options: SpawnOptions,
) !void {
    std.debug.assert(process.child == null);
    std.debug.assert(process.status == .pending);

    std.debug.assert(!process.environ.contains(constants.env_client_uuid));
    std.debug.assert(!process.environ.contains(constants.env_expect_viewport_key));

    const string = process.uuid.serialize();
    try process.environ.put(constants.env_client_uuid, &string);
    try process.environ.put(constants.env_expect_viewport_key, constants.env_expect_viewport_true);

    process.child = try std.process.spawn(process.io, .{
        .argv = process.argv,
        .environ_map = &process.environ,
        .stdout = options.stdout,
        .stderr = options.stderr,
        .stdin = options.stdin,
    });
}

pub fn client_connected(process: *Process) void {
    std.debug.assert(process.status == .pending);
    process.status = .connected;
}

pub const Status = enum {
    connected,
    pending,
    disconnected,
};

pub const SpawnOptions = struct {
    stdout: std.process.SpawnOptions.StdIo = .close,
    stderr: std.process.SpawnOptions.StdIo = .close,
    stdin: std.process.SpawnOptions.StdIo = .close,
};

const std = @import("std");
const Io = std.Io;
const constants = @import("constants");
const ptypes = @import("protocol").types;
