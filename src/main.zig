const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const process = std.process;

// This is used as the size of the buffer, in bytes,
// when reading a present file.
// It's "dumb" because I haven't spent much thought on whether it's a good number or not.
const dumb_max_line_size = 256;
// It's "dumb" because I haven't spent much thought on whether it's a good number or not.
const dumb_max_file_lines = 1024;

// When enabled, prints some helpful tips during the presentation.
// e.g. "Press enter for next slide."
const helpful = false;

const USAGE =
    \\Usage: zig-present [--no-clear] <presentation.txt>
;

var no_clear: bool = false;

const CommandType = enum {
    clearScreen,
    printText,
    waitForEnter,
    goToNextSlide,
    runDocker,
    runShell,
};

const Command = union(CommandType) {
    clearScreen: void,
    printText: struct {
        text: []const u8,
    },
    waitForEnter: struct {
        prompt: []const u8,
    },
    goToNextSlide: struct {
        prompt: []const u8,
    },
    runDocker: struct {
        cmd: []const u8,
    },
    runShell: struct {
        cmd: []const u8,
    },

    pub fn run(self: Command, allocator: std.mem.Allocator, reader: anytype, writer: anytype) !void {
        switch (self) {
            .clearScreen => try clearScreen(allocator, writer),
            .waitForEnter => |wfe| {
                try writer.print("{s}", .{wfe.prompt});
                waitForEnter(reader);
            },
            .printText => |pt| try writer.print("{s}\n", .{pt.text}),
            .goToNextSlide => |go| try goToNextSlide(allocator, reader, writer, go.prompt),
            .runShell => |rs| try runShell(allocator, rs.cmd),
            .runDocker => |rd| try runDocker(allocator, rd.cmd),
        }
    }

    fn runDocker(allocator: std.mem.Allocator, docker_command: []const u8) !void {
        var child_proc = process.Child.init(&.{ "sh", "-c", docker_command }, allocator);
        _ = try child_proc.spawnAndWait();
    }

    fn runShell(allocator: std.mem.Allocator, shell_command: []const u8) !void {
        var child_proc = process.Child.init(&.{ "sh", "-c", shell_command }, allocator);
        _ = try child_proc.spawnAndWait();
    }

    fn clearScreen(allocator: std.mem.Allocator, writer: anytype) !void {
        if (!no_clear) {
            _ = try writer.write("\x1b[2J");
            var child_proc = process.Child.init(&.{ "tput", "cup", "0", "0" }, allocator);
            _ = try child_proc.spawnAndWait();
        }
    }

    fn goToNextSlide(allocator: std.mem.Allocator, reader: anytype, writer: anytype, text: []const u8) !void {
        try writer.print("{s}", .{text});
        waitForEnter(reader);
        try clearScreen(allocator, writer);
    }
};

inline fn waitForEnter(reader: anytype) void {
    reader.skipUntilDelimiterOrEof('\n') catch {};
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa.deinit()) {
        .ok => {},
        else => {
            std.log.info("Oops! A memory leak...", .{});
        },
    };
    const allocator = gpa.allocator();

    var it = try std.process.ArgIterator.initWithAllocator(allocator);
    defer it.deinit();
    const file_path = blk: {
        var value: ?[]const u8 = null;

        // skip exe name
        _ = it.next();
        value = it.next();

        if (value == null or std.mem.eql(u8, value.?, "-h") or std.mem.eql(u8, value.?, "--help")) {
            std.log.info("{s}", .{USAGE});
            std.process.exit(1);
        }

        if (std.mem.eql(u8, value.?, "--no-clear")) {
            no_clear = true;
            value = it.next();
        }

        if (it.next() != null or value == null) {
            std.log.info("{s}", .{USAGE});
            std.process.exit(1);
        }

        std.log.info("file_path=({s})", .{value.?});
        break :blk value.?;
    };

    // All memory allocated with this arena will live until the presentation
    // has completed.
    var presentation_arena = heap.ArenaAllocator.init(allocator);
    defer presentation_arena.deinit();

    const arena = presentation_arena.allocator();

    var commands = std.ArrayList(Command).init(arena);
    try commands.append(.{ .goToNextSlide = .{ .prompt = "" } });

    {
        const cwd = std.fs.cwd();
        var file = cwd.openFile(file_path, .{ .mode = .read_only }) catch |err| {
            debug.print("Encountered an error when opening the present file: {any}\n", .{err});
            process.exit(1);
        };
        defer file.close();
        try readCommandsFromFile(arena, &file, &commands);
    }

    const total_slides = blk: {
        var count: usize = 0;
        for (commands.items) |cmd| {
            switch (cmd) {
                .goToNextSlide => {
                    count += 1;
                },
                else => {},
            }
        }
        break :blk count;
    };

    var slide_no: usize = 0;

    if (helpful) std.log.info("Press enter to begin.", .{});

    for (commands.items, 0..) |cmd, index| {
        try cmd.run(
            allocator,
            std.io.getStdIn().reader(),
            std.io.getStdOut().writer(),
        );

        switch (cmd) {
            .goToNextSlide => {
                slide_no += 1;
                std.log.info("Slide {d}/{d}", .{ slide_no, total_slides });
            },
            else => {},
        }

        if (helpful) {
            if (index + 1 < commands.items.len - 1) {
                switch (commands.items[index + 1]) {
                    .goToNextSlide => {
                        std.log.info("Press enter for next slide.", .{});
                    },
                    else => {},
                }
            }
        }
    }
}

fn readCommandsFromFile(arena: mem.Allocator, file: *fs.File, list: *std.ArrayList(Command)) !void {
    var state: enum {
        readPreamble,
        readCommand,
    } = .readPreamble;

    var buf: [dumb_max_line_size]u8 = undefined;
    var num_iters: u64 = 0;
    loop: while (num_iters < dumb_max_file_lines) : (num_iters += 1) {
        const line = file.reader().readUntilDelimiter(&buf, '\n') catch |err| {
            switch (err) {
                error.EndOfStream => {
                    break :loop;
                },
                else => {
                    return err;
                },
            }
        };

        switch (state) {
            .readPreamble => {
                if (!std.mem.eql(u8, line, "!zig-present")) {
                    debug.print("Malformed present file. First line must be exactly '!zig-present' (without the quotes).", .{});
                    process.exit(1);
                }
                state = .readCommand;
            },
            .readCommand => {
                const stdout_prefix = "/stdout ";
                try list.append(cmd: {
                    if (line.len == 0) break :cmd .{ .printText = .{ .text = "" } };
                    if (mem.startsWith(u8, line, stdout_prefix)) {
                        debug.assert(line.len < stdout_prefix.len + 1);

                        break :cmd .{ .runShell = .{ .cmd = try arena.dupe(u8, line[stdout_prefix.len..]) } };
                    }

                    if (mem.startsWith(u8, line, "/next_slide")) break :cmd .{
                        .goToNextSlide = .{
                            .prompt = try arena.dupe(u8, mem.trim(u8, line["/next_slide".len..], " ")),
                        },
                    };
                    if (mem.startsWith(u8, line, "/pause")) break :cmd .{
                        .waitForEnter = .{
                            .prompt = try arena.dupe(u8, mem.trim(u8, line["/pause".len..], " ")),
                        },
                    };
                    if (mem.startsWith(u8, line, "/docker")) break :cmd .{
                        .runDocker = .{
                            .cmd = try arena.dupe(u8, line[1..]),
                        },
                    };

                    break :cmd .{ .printText = .{ .text = try arena.dupe(u8, line) } };
                });
            },
        }
    }

    debug.assert(num_iters < dumb_max_file_lines);
}
