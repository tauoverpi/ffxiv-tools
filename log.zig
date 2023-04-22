//! FFXIV Log parsing utils

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

const esc = std.fmt.fmtSliceEscapeUpper;
const hex = std.fmt.fmtSliceHexUpper;

const Allocator = std.mem.Allocator;

pub const Table = struct {
    //! The FFXIV log file format consists of two leading 32-bit integers encoding the length of the
    //! file and body, a table header consisting of end-of-line offsets, and a string table consisting
    //! of three records: timestamp + channel, name, and text.

    offsets: []const u32,
    pool: []const u8,

    pub fn deinit(self: *Table, gpa: Allocator) void {
        const base = mem.sliceAsBytes(self.offsets).ptr - 8;
        gpa.free(base[0 .. 8 + self.offsets.len * 4 + self.pool.len]);
    }

    pub fn load(gpa: Allocator, path: []const u8) !Table {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();

        const table = try gpa.alignedAlloc(u8, 8, stat.size);
        errdefer gpa.free(table);

        assert(try file.readAll(table) == stat.size);

        const body = @bitCast(u32, table[0..4].*);
        const size = @bitCast(u32, table[4..8].*) - body;
        const offsets = table[8 .. 8 + size * 4];
        const pool = table[8 + size * 4 ..];

        return .{
            .offsets = mem.bytesAsSlice(u32, offsets),
            .pool = pool,
        };
    }

    pub fn iterator(self: *const Table, filter: Iterator.Message.Filter) Iterator {
        return .{ .table = self, .filter = filter };
    }

    pub const Iterator = struct {
        table: *const Table,
        index: usize = 0,
        start: usize = 0,
        filter: Message.Filter,

        pub const Message = struct {
            meta: ?Meta,
            name: []const u8,
            text: []const u8,

            pub const Meta = packed struct(u64) {
                time: u32,
                chan: Channel,
                unknown: u8,
                pad: u16 = 0,
            };

            pub const FilterInt = @Type(.{ .Int = .{
                .signedness = .unsigned,
                .bits = @bitSizeOf(Filter),
            } });

            pub const Filter = blk: {
                const StructField = std.builtin.Type.StructField;
                const info = @typeInfo(Channel).Enum.fields;

                var fields: [info.len]StructField = undefined;
                for (&fields, info) |*field, src| {
                    field.* = .{
                        .name = src.name,
                        .type = bool,
                        .alignment = 0,
                        .default_value = &false,
                        .is_comptime = false,
                    };
                }

                break :blk @Type(.{ .Struct = .{
                    .layout = .Packed,
                    .fields = &fields,
                    .decls = &.{},
                    .is_tuple = false,
                } });
            };

            pub const Channel = enum(u8) {
                motd = 0x03,
                say = 0x0a,
                shout = 0x0b,
                outgoing_tell = 0x0c,
                incoming_tell = 0x0d,
                party = 0x0e,
                linkshell = 0x10,
                free_company = 0x18,
                emote = 0x1d,
                yell = 0x1e,
                incoming_damage = 0x29,
                incoming_miss = 0x2a,
                cast = 0x2b,
                consume_item = 0x2c,
                recover_hp = 0x2d,
                player_buff = 0x2e,
                status_effect = 0x2f,
                echo = 0x38,
                notification = 0x39,
                defeat = 0x3a,
                err = 0x3c,
                npc_chat = 0x3d,
                obtain = 0x3e,
                exp = 0x40,
                roll = 0x41,
                free_company_event = 0x45,
                outgoing_damage = 0xa9,
                outgoing_miss = 0xaa,
                begin_cast = 0xab,
                buff = 0xae,
                effect = 0xaf,
                defeated = 0xba,
                self_lose_effect = 0xb0,
                lose_effect = 0x30,
                recover_from_effect = 0xb1,
                recruiting = 0x48,
                self_recover_hp = 0xad,
                login = 0x46,
                recovers = 0x31,
                self_obtain = 0xbe,

                npc_yell = 0x44, // maybe?

                /// observed: accept, complete
                quest = 0xb9,
                unknown_2 = 0x1c,
                unknown_3 = 0x42,
                unknown_5 = 0xac,
            };
        };

        pub fn next(self: *Iterator) ?Message {
            const int = @bitCast(Message.FilterInt, self.filter);

            while (true) {
                if (self.index >= self.table.offsets.len) return null;

                defer self.index += 1;
                const end = self.table.offsets[self.index];
                defer self.start = end;

                const triple = self.table.pool[self.start..end];
                var it = mem.split(u8, triple, "\x1f");

                const meta = it.next().?;
                const name = it.next().?;
                const text = it.next().?;

                if (meta.len < 8) {
                    if (int == 0) return .{
                        .meta = null,
                        .name = name,
                        .text = text,
                    };
                } else {
                    const m = @bitCast(Message.Meta, meta[0..8].*);

                    // std.debug.print("tag: {[tag]d} {[tag]x}\n", .{ .tag = @enumToInt(m.chan) });
                    const cont = if (int == 0) true else switch (m.chan) {
                        inline else => |tag| @field(self.filter, @tagName(tag)),
                    };

                    if (cont) return .{
                        .meta = m,
                        .name = name,
                        .text = text,
                    };
                }
            }
        }
    };
};

fn help(flag: ?[]const u8) !u8 {
    const stderr = std.io.getStdErr().writer();

    if (flag) |unknown| {
        try stderr.print(
            \\unknown option: {s}
            \\
        , .{unknown});
    }

    try stderr.writeAll(
        \\usage: log [options] files
        \\
        \\
    );

    inline for (@typeInfo(Table.Iterator.Message.Filter).Struct.fields) |field| {
        try stderr.writeAll("  --" ++ field.name ++ "\n");
    }

    return @boolToInt(flag != null);
}

pub fn main() !u8 {
    var instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!instance.deinit());
    const gpa = instance.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    var flags: Table.Iterator.Message.Filter = .{};

    var buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = buffer.writer();

    cont: for (argv[1..]) |arg| {
        if (mem.eql(u8, arg, "--")) break;
        if (mem.startsWith(u8, arg, "--")) {
            const flag = arg["--".len..];
            inline for (@typeInfo(Table.Iterator.Message.Filter).Struct.fields) |field| {
                if (mem.eql(u8, flag, field.name)) {
                    @field(flags, field.name) = true;
                    continue :cont;
                }
            }

            return try help(flag);
        }
    }

    var ignore_flags = false;
    for (argv[1..]) |arg| {
        if (!ignore_flags and mem.startsWith(u8, arg, "--")) {
            if (mem.eql(u8, arg, "--")) ignore_flags = true;
            continue;
        }

        var table = try Table.load(gpa, arg);
        defer table.deinit(gpa);

        var it = table.iterator(flags);

        while (it.next()) |message| if (message.meta) |meta| {
            try stdout.print(
                \\time: {d}
                \\chan: {}
                \\name: {s}
                \\text: {s}
                \\
                \\
            , .{
                meta.time,
                meta.chan,
                message.name,
                esc(message.text),
            });
        };
    }

    try buffer.flush();

    return 0;
}
