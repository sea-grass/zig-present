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
    \\Usage: zig-present [--no-clear] <presentation.txt>
;

var no_clear: bool = false;

const CommandType = enum {
    printText,
    waitForEnter,
    goToNextSlide,
    runDocker,
    runShell,
};

const Command = union(CommandType) {
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

    pub fn parseLeaky(arena: mem.Allocator, line: []const u8) !?Command {
        if (mem.startsWith(u8, line, "/stdout")) {
            return .{ .runShell = .{ .cmd = try arena.dupe(u8, line["/stdout".len..]) } };
        }

        if (mem.startsWith(u8, line, "/next_slide")) return .{
            .goToNextSlide = .{
                .prompt = try arena.dupe(u8, mem.trim(u8, line["/next_slide".len..], " ")),
            },
        };

        if (mem.startsWith(u8, line, "/pause")) return .{
            .waitForEnter = .{
                .prompt = try arena.dupe(u8, mem.trim(u8, line["/pause".len..], " ")),
            },
        };

        if (mem.startsWith(u8, line, "/docker")) return .{
            .runDocker = .{
                .cmd = try arena.dupe(u8, line[1..]),
            },
        };

        return null;
    }

    pub fn dispatch(self: Command, allocator: std.mem.Allocator, reader: anytype, writer: anytype) !void {
        switch (self) {
            .printText => |pt| try writer.print("{s}\n", .{pt.text}),
            .waitForEnter => |wfe| {
                try writer.print("{s}", .{wfe.prompt});
                waitForEnter(reader);
            },
            .goToNextSlide => |go| {
                try writer.print("{s}", .{go.prompt});
                waitForEnter(reader);
                try clearScreen(writer);
            },
            .runShell => |rs| {
                var p = process.Child.init(&.{ "sh", "-c", rs.cmd }, allocator);
                _ = try p.spawnAndWait();
            },
            .runDocker => |rd| {
                var p = process.Child.init(&.{ "sh", "-c", rd.cmd }, allocator);
                _ = try p.spawnAndWait();
            },
        }
    }

    fn clearScreen(writer: anytype) !void {
        if (!no_clear) {
            _ = try writer.write("\x1b[2J");
            var buf: [required_mem_by_tput]u8 = undefined;
            var fba = heap.FixedBufferAllocator.init(&buf);
            var child_proc = process.Child.init(&.{ "tput", "cup", "0", "0" }, fba.allocator());
            _ = try child_proc.spawnAndWait();
        }
    }
};

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

        if (value == null or it.next() != null) {
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
    if (helpful) std.log.info("Press enter to begin.", .{});

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

    for (commands.items, 0..) |cmd, index| {
        try cmd.dispatch(
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

        if (helpful and index + 1 < commands.items.len - 1) {
            switch (commands.items[index + 1]) {
                .goToNextSlide => {
                    std.log.info("Press enter for next slide.", .{});
                },
                else => {},
            }
        }
    }
}

fn readCommandsFromFile(arena: mem.Allocator, file: *fs.File, list: *std.ArrayList(Command)) !void {
    var buf: [dumb_max_line_size]u8 = undefined;

    if (!mem.eql(u8, try file.reader().readUntilDelimiter(&buf, '\n'), "!zig-present")) {
        debug.print("Malformed present file. First line must be exactly '!zig-present' (without the quotes).", .{});
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
