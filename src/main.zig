const std = @import("std");

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
    waitForEnter: void,
    goToNextSlide: void,
    runDocker: struct {
        docker_command: []const u8,
    },
    runShell: struct {
        shell_command: []const u8,
    },

    const Impl = struct {
        pub fn runDocker(allocator: std.mem.Allocator, docker_command: []const u8) !void {
            var child_proc = std.ChildProcess.init(&.{ "sh", "-c", docker_command }, allocator);
            try child_proc.spawn();

            _ = try child_proc.wait();
        }

        pub fn runShell(allocator: std.mem.Allocator, shell_command: []const u8) !void {
            var child_proc = std.ChildProcess.init(&.{ "sh", "-c", shell_command }, allocator);
            try child_proc.spawn();

            _ = try child_proc.wait();
        }

        pub fn clearScreen(allocator: std.mem.Allocator, writer: anytype) !void {
            _ = try writer.write("\x1b[2J");
            var child_proc = std.ChildProcess.init(&.{ "tput", "cup", "0", "0" }, allocator);
            try child_proc.spawn();

            _ = try child_proc.wait();
        }

        pub fn goToNextSlide(allocator: std.mem.Allocator, reader: anytype, writer: anytype) !void {
            waitForEnter(reader);
            try Impl.clearScreen(allocator, writer);
        }
    };

    pub fn run(self: Command, allocator: std.mem.Allocator, reader: anytype, writer: anytype) !void {
        switch (self) {
            .clearScreen => try Impl.clearScreen(allocator, writer),
            .waitForEnter => waitForEnter(reader),
            .printText => try writer.print("{s}\n", .{self.printText.text}),
            .goToNextSlide => try Impl.goToNextSlide(allocator, reader, writer),
            .runShell => try Impl.runShell(allocator, self.runShell.shell_command),
            .runDocker => try Impl.runDocker(allocator, self.runDocker.docker_command),
        }
    }

    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
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

    var child_proc = std.ChildProcess.init(&.{ "zig", "build" }, allocator);
    try child_proc.spawn();

    _ = try child_proc.wait();

    const file_path = blk: {
        var it = std.process.args();
        var value: ?[]const u8 = null;

        // skip exe name
        _ = it.next();
        if (it.next()) |v| value = v;

        if (it.next() != null or value == null) {
            std.log.info("Usage: zig-present <presentation.txt>", .{});
            std.process.exit(1);
        }

        std.log.info("file_path=({s})", .{value.?});
        break :blk value.?;
    };

    const cwd = std.fs.cwd();
    var file = cwd.readFileAlloc(allocator, file_path, std.math.maxInt(usize)) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.log.info("File not found.", .{});
                std.process.exit(1);
            },
            else => {
                std.log.info("Error reading file.", .{});
                std.process.exit(1);
            },
        }
    };
    defer allocator.free(file);

    var commands = std.ArrayList(Command).init(allocator);
    defer {
        while (commands.items.len > 0) {
            commands.pop().deinit(allocator);
        }
        commands.deinit();
    }

    var line_it = std.mem.splitScalar(u8, file, '\n');

    try commands.append(.goToNextSlide);

    var state: enum {
        readPreamble,
        readCommand,
    } = .readPreamble;

    while (line_it.next()) |line| {
        switch (state) {
            .readPreamble => {
                if (!std.mem.eql(u8, line, "!zig-present")) {
                    std.log.info("Malformed present file. First line must be exactly '!zig-present' (without the quotes).", .{});
                    std.process.exit(1);
                }
                state = .readCommand;
            },
            .readCommand => {
                const stdout_prefix = "/stdout ";
                if (line.len == 0) {
                    try commands.append(.{
                        .printText = .{ .text = "" },
                    });
                } else if (std.mem.startsWith(u8, line, stdout_prefix)) {
                    if (line.len < stdout_prefix.len + 1) @panic("Malformed command. Usage: /stdout <command>");
                    const shell_command = line[stdout_prefix.len..];
                    try commands.append(.{
                        .runShell = .{ .shell_command = shell_command },
                    });
                } else if (std.mem.startsWith(u8, line, "/next_slide")) {
                    try commands.append(.goToNextSlide);
                } else if (std.mem.startsWith(u8, line, "/pause")) {
                    try commands.append(.waitForEnter);
                } else if (std.mem.startsWith(u8, line, "/docker")) {
                    const docker_command = line[1..];
                    try commands.append(.{
                        .runDocker = .{ .docker_command = docker_command },
                    });
                } else {
                    try commands.append(.{
                        .printText = .{ .text = line },
                    });
                }
            },
        }
    }

    std.log.info("Press enter to begin.", .{});
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
