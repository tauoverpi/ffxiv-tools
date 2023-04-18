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

    pub fn iterator(self: *const Table) Iterator {
        return .{ .table = self };
    }

    pub const Iterator = struct {
        table: *const Table,
        index: usize = 0,
        start: usize = 0,

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
                login = 0x45,
                outgoing_damage = 0xa9,
                outgoing_miss = 0xaa,
                begin_cast = 0xab,
                buff = 0xae,
                effect = 0xaf,
                defeated = 0xba,
                _,
            };
        };

        pub fn next(self: *Iterator) ?Message {
            if (self.index >= self.table.offsets.len) return null;

            defer self.index += 1;
            const end = self.table.offsets[self.index];
            defer self.start = end;

            const triple = self.table.pool[self.start..end];
            var it = mem.split(u8, triple, "\x1f");

            const meta = it.next().?;
            const name = it.next().?;
            const text = it.next().?;

            return .{
                .meta = if (meta.len < 8) null else @bitCast(Message.Meta, meta[0..8].*),
                .name = name,
                .text = text,
            };
        }
    };
};

pub fn main() !void {
    var instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!instance.deinit());
    const gpa = instance.allocator();

    for (std.os.argv[1..]) |arg| {
        var table = try Table.load(gpa, mem.span(arg));
        defer table.deinit(gpa);

        var it = table.iterator();

        while (it.next()) |message| if (message.meta) |meta| {
            switch (meta.chan) {
                .outgoing_miss,
                .outgoing_damage,
                .incoming_miss,
                .incoming_damage,
                .defeat,
                .begin_cast,
                .effect,
                .cast,
                .defeated,
                .recover_hp,
                .player_buff,
                .buff,
                .status_effect,
                => std.debug.print(
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
                    message.text,
                }),
                else => {},
            }
        };
    }
}
