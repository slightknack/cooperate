const std = @import("std");
const k = 16;

const Range = struct {
    start: u32,
    end: u32,
};

pub fn Rope(comptime item: type) type {
    return union(enum) {
        const Self = @This();
        node: struct {
            childs: [k]*Self,
            child_sizes: [k]u32,
        },
        leaf: [k]item,
    };

    fn nodeAt(self: *Self, index: u32) struct { node: *Self, index: u32, } {
    }

    fn insert(self: *Self, index: u32, edit: []item) void {

    }

    fn replace(self: *Self, range: Range, edit: []item) void {

    }
}
