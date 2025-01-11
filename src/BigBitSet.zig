const std = @import("std");
const Self = @This();

/// maximum size: 4_294_967_295.
/// range is inclusive at both ends.
const Range = struct {
    block_start: u32,
    block_end: u32,
};

const Packed = struct {
    block: u32,
    data: u128,
};

ranges: std.AutoHashMap(Range),
packeds: std.AutoHashMap(u32, u128),
size: u64,

pub fn initEmpty(allocator: std.mem.Allocator, size: u64) Self {
    return Self{
        std.ArrayList(Range).init(allocator),
        std.ArrayList(Packed).init(allocator),
        size,
    };
}

fn packedFor(self: Self, block: u32) Packed {
    const start: usize = @intCast(block * 128);
}
