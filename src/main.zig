const std = @import("std");
// const BigBigSet = @import("BigBitSet.zig");
// const Skiplist = @import("skiplist.zig").Skiplist;
const SkipList = @import("skiplist2.zig").SkipList;

const KeyPublic = [32]u8;
const KeyPrivate = [32]u8;
const KeyPair = struct {
    private: KeyPrivate,
    public: KeyPublic,
};

const Stream = struct {
    const Self = @This();
    data: std.ArrayList(u8),
    // key_pair: KeyPair,

    fn write(self: *Self, data: []u8) StreamSlice {
        const start = self.data.items.len;
        const end = start + data.len;
        self.data.appendSlice(data);
        return StreamSlice{ start, end };
    }
};
const StreamSlice = struct {
    start: usize,
    end: usize,
};

const Frag = [1024]u8;

const StreamReader = struct {
    frags: std.AutoHashMap(u32, Frag),
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) @panic("memory leak");

    var sl = SkipList(u8, 16).init();
    const out = sl.towerFor(0);
    std.debug.print("{}\n", .{out.index});
    // std.debug.print("{}", .{out.tower});

    std.debug.print("Hello, World\n", .{});
    // const bbs = BigBigSet.initEmpty(std.testing.allocator, 3);
    // var sl = try Skiplist(u8, 16).init(allocator);
    // defer sl.deinit();

    // var hello: [18]u8 = "heloheloheloheloxx".*;
    // _ = try sl.insert(0, &hello);
    // _ = try sl.insert(16, &hello);
    // sl.debug();
    _ = allocator;
}
