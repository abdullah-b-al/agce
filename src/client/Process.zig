const Process = @This();

io: Io,
arena: std.heap.ArenaAllocator,
argv: []const []const u8,
environ: std.process.Environ.Map,

full_id: ?ptypes.ClientFullID,
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
        .argv = argv,
        .full_id = null,
        .child = null,
        .environ = environ,
        .err = null,
        .status = .pending_id,
    };

    return process;
}

pub fn destroy(process: *Process, gpa: std.mem.Allocator) void {
    if (process.child) |*child| {
        child.kill(process.io);
    }
    process.arena.deinit();
    gpa.destroy(process);
}

pub fn spawn(
    process: *Process,
    options: SpawnOptions,
) !void {
    std.debug.assert(process.child == null);
    std.debug.assert(process.full_id != null);
    std.debug.assert(process.status == .can_spawn);

    const full_id = process.full_id.?;
    var buf: [ptypes.ClientFullID.env_string_max_len]u8 = undefined;
    const string = full_id.to_env_string(&buf);

    std.debug.assert(!process.environ.contains(constants.env_client_full_id));
    std.debug.assert(!process.environ.contains(constants.env_expect_viewport_key));

    try process.environ.put(constants.env_client_full_id, string);
    try process.environ.put(constants.env_expect_viewport_key, constants.env_expect_viewport_true);

    process.child = try std.process.spawn(process.io, .{
        .argv = process.argv,
        .environ_map = &process.environ,
        .stdout = options.stdout,
        .stderr = options.stderr,
        .stdin = options.stdin,
    });

    process.status = .pending_connection;
}

pub fn received_id(process: *Process, full_id: ptypes.ClientFullID) void {
    std.debug.assert(process.status == .pending_id);
    process.full_id = full_id;
    process.status = .can_spawn;
}

pub fn client_connected(process: *Process) void {
    std.debug.assert(process.status == .pending_connection);
    std.debug.assert(process.full_id != null);
    process.status = .{ .connected = process.full_id.?.id };
}

pub const Status = union(enum) {
    pending_id,
    pending_connection,
    connected: ptypes.ClientID,
    can_spawn,
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
