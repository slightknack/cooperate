const std = @import("std");
const List = std.SinglyLinkedList;
const Alloc = std.mem.Allocator;

fn Leaf(comptime item: type, comptime k: usize) type {
    return List(StaticArray(item, k)).Node;
}

fn Lane(comptime item: type, comptime k: usize) type {
    return List(struct {
        const Self = @This();
        const Node = Lane(item, k).Node;
        width: u32,
        down: union(enum) {
            lane: *Node,
            leaf: Leaf(item, k),
        },
    }).Node;
}

fn StaticArray(comptime item: type, comptime k: usize) type {
    return struct {
        const Self = @This();
        items: [k]item,
        len: u32,

        fn init() Self {
            return Self{
                .items = undefined,
                .len = 0,
            };
        }

        fn last(self: Self) ?item {
            if (self.len == 0) return null;
            return self.items[self.len - 1];
        }

        fn first(self: Self) ?item {
            if (self.len == 0) return null;
            return self.items[0];
        }

        // writes data to static array. returns items written
        fn write(self: Self, data: []item) usize {
            const space = @min(k - self.len, data.len);
            std.mem.copyForwards(item, self.items[self.len .. self.len + space], data[0..data.len]);
            self.len += space;
            return space;
        }
    };
}

pub fn SkipList(comptime item: type, comptime k: usize) type {
    return struct {
        const layers: usize = 20;
        const Self = @This();
        const Node = Lane(item, k).Node;
        const Tower = StaticArray(*Node, layers);

        tower: Tower,
        arrays: Leaf(item, k),
        items: usize,

        pub fn init() Self {
            return Self{
                .tower = Tower.init(),
                .arrays = Leaf(item, k){},
                .items = 0,
            };
        }

        pub fn towerFor(self: *Self, index: usize) struct {
            tower: Tower,
            index: usize,
        } {
            var layer = self.tower.len;
            var seen: usize = 0;
            var tower = self.tower;
            if (self.tower.top()) |list| {
                var node: ?*Node = list;
                while (node) |it| {
                    seen += it.data.width;
                    if (seen >= index) {
                        layer -= 1;
                        tower.items[layer] = it;
                        seen -= it.data.width;
                        node = switch (it.data.down) {
                            .lane => |lane| lane,
                            .leaf => break,
                        };
                    }
                }
            }
            return .{
                .tower = tower,
                .index = seen,
            };
        }

        fn insert(self: *Self, index: usize, data: []item) error{OutOfMemory}!void {
            // get the tower and get a place to append.
            const out = self.towerFor(index);
            const start = index - out.index;
            const array = out.tower.bottom() orelse self.arrays.first;
        }
    };
}
