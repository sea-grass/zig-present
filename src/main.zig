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
const required_mem_by_tput = 4096;

// When enabled, prints some helpful tips during the presentation.
// e.g. "Press enter for next slide."
const helpful = false;

const USAGE =
    \\NAME
    \\  zig-present - Interactive terminal presentations
    \\
    \\SYNOPSIS
    \\  zig-present [OPTION] [FILE]
    \\
    \\DESCRIPTION
    \\  Parse the presentation from the FILE and begin an interactive session.
    \\
    \\  -h, --help
    \\      Print this help message.
    \\
    \\  --no-clear
    \\      Do not clear the screen contents between slides.
;

const Args = struct {
    file_path: []const u8,
    no_clear: bool,

    pub const help = &.{ "-h", "--help" };
    pub const no_clear = "--no-clear";

    pub fn parse(it: *process.ArgIterator) !Args {
        var args: Args = undefined;
        args.no_clear = false;

        // skip exe name
        _ = it.next();

        var token: []const u8 = it.next() orelse {
            debug.print("{s}\n", .{USAGE});
            std.process.exit(1);
        };

        inline for (help) |h| {
            if (std.mem.eql(u8, token, h)) {
                debug.print("{s}\n", .{USAGE});
                std.process.exit(0);
            }
        }

        if (std.mem.eql(u8, token, no_clear)) {
            args.no_clear = true;

            token = it.next() orelse {
                debug.print("{s}\n", .{USAGE});
                std.process.exit(1);
            };
        }

        // Ensure there are no extraneous arguments
        if (it.next() != null) {
            debug.print("{s}\n", .{USAGE});
            std.process.exit(1);
        }

        args.file_path = token;

        return args;
    }
};

const CommandType = enum {
    goToNextSlide,
    printText,
    runDocker,
    runShell,
    waitForEnter,
};

const Command = union(CommandType) {
    goToNextSlide: struct {
        prompt: []const u8,
    },
    printText: struct {
        text: []const u8,
    },
    runDocker: struct {
        cmd: []const u8,
    },
    runShell: struct {
        cmd: []const u8,
    },
    waitForEnter: struct {
        prompt: []const u8,
    },

    pub fn parseLeaky(arena: mem.Allocator, line: []const u8) !?Command {
        if (line.len == 0) return null;
        if (line[0] != '/') return null;

        if (mem.startsWith(u8, line, "/next_slide")) {
            const prompt = try arena.dupe(u8, mem.trim(u8, line["/next_slide".len..], " "));
            return .{
                .goToNextSlide = .{
                    .prompt = prompt,
                },
            };
        }

        if (mem.startsWith(u8, line, "/docker")) {
            const cmd = try arena.dupe(u8, line[1..]);
            return .{
                .runDocker = .{
                    .cmd = cmd,
                },
            };
        }

        if (mem.startsWith(u8, line, "/stdout")) {
            const cmd = try arena.dupe(u8, line["/stdout".len..]);
            return .{ .runShell = .{ .cmd = cmd } };
        }

        if (mem.startsWith(u8, line, "/pause")) {
            const prompt = try arena.dupe(u8, mem.trim(u8, line["/pause".len..], " "));
            return .{
                .waitForEnter = .{
                    .prompt = prompt,
                },
            };
        }

        return null;
    }

    pub fn dispatch(self: Command, allocator: std.mem.Allocator, reader: anytype, writer: anytype, no_clear: bool) !void {
        switch (self) {
            .goToNextSlide => |go| {
                try writer.print("{s}", .{go.prompt});
                waitForEnter(reader);
                if (!no_clear) {
                    try clearScreen(writer);
                }
            },
            .printText => |pt| try writer.print("{s}\n", .{pt.text}),
            .runDocker => |rd| {
                var p = process.Child.init(&.{ "sh", "-c", rd.cmd }, allocator);
                _ = try p.spawnAndWait();
            },
            .runShell => |rs| {
                var p = process.Child.init(&.{ "sh", "-c", rs.cmd }, allocator);
                _ = try p.spawnAndWait();
            },
            .waitForEnter => |wfe| {
                try writer.print("{s}", .{wfe.prompt});
                waitForEnter(reader);
            },
        }
    }

    fn clearScreen(writer: anytype) !void {
        _ = try writer.write("\x1b[2J");
        var buf: [required_mem_by_tput]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&buf);
        var child_proc = process.Child.init(&.{ "tput", "cup", "0", "0" }, fba.allocator());
        _ = try child_proc.spawnAndWait();
    }
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa.deinit()) {
        .ok => {},
        else => {
            debug.print("Oops! A memory leak...", .{});
        },
    };
    const allocator = gpa.allocator();

    var it = try process.ArgIterator.initWithAllocator(allocator);
    defer it.deinit();

    const args = try Args.parse(&it);

    debug.print("file_path=({s})\n", .{args.file_path});

    // All memory allocated with this arena will live until the presentation
    // has completed.
    var presentation_arena = heap.ArenaAllocator.init(allocator);
    defer presentation_arena.deinit();

    const arena = presentation_arena.allocator();

    var commands = std.ArrayList(Command).init(arena);

    try commands.append(.{ .goToNextSlide = .{ .prompt = "" } });
    if (helpful) debug.print("Press enter to begin.\n", .{});

    {
        const cwd = std.fs.cwd();
        var file = cwd.openFile(args.file_path, .{ .mode = .read_only }) catch |err| {
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

    for (commands.items, 0..) |cmd, index| {
        try cmd.dispatch(
            allocator,
            std.io.getStdIn().reader(),
            std.io.getStdOut().writer(),
            args.no_clear,
        );

        switch (cmd) {
            .goToNextSlide => {
                slide_no += 1;
                debug.print("Slide {d}/{d}\n", .{ slide_no, total_slides });
            },
            else => {},
        }

        if (helpful and index + 1 < commands.items.len - 1) {
            switch (commands.items[index + 1]) {
                .goToNextSlide => {
                    debug.print("Press enter for next slide.\n", .{});
                },
                else => {},
            }
        }
    }
}

fn readCommandsFromFile(arena: mem.Allocator, file: *fs.File, list: *std.ArrayList(Command)) !void {
    var buf: [dumb_max_line_size]u8 = undefined;

    if (!mem.eql(u8, try file.reader().readUntilDelimiter(&buf, '\n'), "!zig-present")) {
        debug.print("Malformed present file. First line must be exactly '!zig-present' (without the quotes).\n", .{});
        process.exit(1);
    }

    var num_iters: u64 = 0;
    defer debug.assert(num_iters < dumb_max_file_lines);

    while (num_iters < dumb_max_file_lines) : (num_iters += 1) {
        const line = file.reader().readUntilDelimiter(&buf, '\n') catch |err| {
            switch (err) {
                error.EndOfStream => return,
                else => return err,
            }
        };

        try list.append(cmd: {
            if (line.len == 0) break :cmd .{ .printText = .{ .text = "" } };
            if (try Command.parseLeaky(arena, line)) |parse_result| break :cmd parse_result;
            break :cmd .{ .printText = .{ .text = try arena.dupe(u8, line) } };
        });
    }
}

inline fn waitForEnter(reader: anytype) void {
    reader.skipUntilDelimiterOrEof('\n') catch {};
}
