const std = @import("std");
const assert = std.debug.assert;

fn Lane(
    comptime item: type,
    comptime k: u32,
) type {
    return struct {
        const Self = @This();

        next: ?*Self,
        width: u32,
        down: union(enum) {
            lane: *Self,
            leaf: *[k]item,
        },

        fn initLeaf(allocator: std.mem.Allocator) error{OutOfMemory}!*Self {
            const self: *Self = try allocator.create(Self);
            const leaf = try allocator.create([k]item);
            self.* = Lane(item, k){
                .next = null,
                .width = 0,
                .down = .{ .leaf = leaf },
            };
            return self;
        }

        fn leafItems(self: *Self) ?*[k]item {
            switch (self.down) {
                .leaf => |items| return items,
                .lane => return null,
            }
        }

        /// data should not be empty lol.
        /// builds lane from some data.
        /// the end of the lane is whatever is in next.
        fn buildLeafLane(
            allocator: std.mem.Allocator,
            data: []item,
            next: ?*Self,
        ) error{OutOfMemory}!struct {
            leaf_node: *Self,
            nodes_created: usize,
        } {
            // we need to build up the list backwards
            const remainder = data.len % k;
            const batches = @divExact(data.len - remainder, k);
            // copy the last partial batch
            var prev: *Self = try Self.initLeaf(allocator);
            std.mem.copyForwards(item, prev.leafItems().?, data[data.len - remainder ..]);
            // okay because width < k < u32 max
            prev.width = @intCast(remainder);
            prev.next = next;
            // iterate through backwards
            for (0..batches) |batch| {
                const start = (batches - batch - 1) * k;
                const node = try Self.initLeaf(allocator);
                std.mem.copyForwards(item, node.leafItems().?, data[start .. start + k]);
                node.width = k;
                node.next = prev;
                prev = node;
            }
            return .{
                .leaf_node = prev,
                .nodes_created = batches + 1,
            };
        }

        fn findNode(
            self: *Self,
            index: u32,
            root: u8,
        ) ?struct {
            // tower is a vertical slice of a skiplist.
            // 0 is the lowest lane and contains the leafs.
            // we need to know root so we know where to start populating it.
            tower: [32]*Self,
            index: u32,
        } {
            var node: *Self = self;
            var seen: u32 = 0;
            var tower: [32]*Self = undefined;
            var level = root;
            while (true) {
                seen += node.width;
                if (seen >= index) {
                    // we have gone too far, drop down a level
                    tower[level] = node;
                    switch (node.down) {
                        .lane => |lane| {
                            level -= 1;
                            seen -= node.width;
                            node = lane;
                        },
                        .leaf => return .{
                            .tower = tower,
                            .index = seen,
                        },
                    }
                }
                if (node.next) |next| {
                    node = next;
                } else {
                    // index is out of bounds.
                    // (we're at the end, and seen is still less than index)
                    return null;
                }
            }
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // free the lanes below this one
            // note: this can be moved into Skiplist
            switch (self.down) {
                // okay because max recursion depth is 32
                .lane => |below| below.deinit(allocator),
                else => {},
            }
            // then clear out the current lane
            var current: ?*Self = self;
            while (current) |node| {
                const next = node.next;
                switch (node.down) {
                    .leaf => |items| allocator.destroy(items),
                    else => {},
                }
                allocator.destroy(node);
                current = next;
            }
        }

        /// append to the end of a leaf node.
        /// this is implementation details.
        /// if you want to insert, use `insert`.
        /// insert calls append.
        fn append(
            self: *Self,
            allocator: std.mem.Allocator,
            data: []item,
        ) error{OutOfMemory}!void {
            if (data.len == 0) {
                return;
            }
            const items: *[k]item = switch (self.down) {
                .lane => @panic("can only append to leaf node"),
                .leaf => |items| items,
            };
            if (self.width < k) {
                const remaining = k - self.width;
                if (remaining <= data.len) {
                    // more data than there is space, take the first bit
                    std.mem.copyForwards(item, items[self.width..k], data[0..remaining]);
                    self.width = k;
                    // put the rest of the data into new slices
                    const result = try Self.buildLeafLane(allocator, data[remaining..], self.next);
                    self.next = result.leaf_node;
                    // only in this case are there new slices.
                    // we need to build a tower for each slice.

                } else {
                    // data fits in slice! add it in place
                    std.mem.copyForwards(item, items[self.width .. self.width + data.len], data[0..]);
                    // @intCast okay because data.len < k < u32 max
                    self.width += @as(u32, @intCast(data.len));
                    // todo: propogate width updwards
                    // todo: insert nodes above probabilistically
                    return;
                }
            }
        }
    };
}

/// Maximum length is 2^32-1 items.
/// Maximum k is 256.
pub fn Skiplist(
    comptime item: type,
    comptime k: usize,
) type {
    comptime assert(k <= 256);
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        // 0 is the lowest lane and contains the leafs.
        // each lane is more sparsely populated.
        tower: [32]*Lane(item, k),
        // this is the topmost lane.
        // it starts at 0 and gets bigger.
        root: u8,
        // number of leafs, not number of items.
        size: u32,

        pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            const e = try Lane(item, k).initLeaf(allocator);
            var self = Self{
                .tower = undefined,
                .root = 0,
                .size = 0,
                .allocator = allocator,
            };
            self.tower[0] = e;
            return self;
        }

        pub fn deinit(self: *Self) void {
            const root_lane = self.tower[self.root];
            root_lane.deinit(self.allocator);
        }

        pub fn insert(self: *Self, index: u32, data: []item) error{OutOfMemory}!void {
            // todo: deal with the case of too much data. see also self.len
            // if (data.len <= 0xFFFFFFFF) {
            //     @panic("too much data to append");
            // }
            // self.len += @intCast(data.len);
            var root = self.tower[self.root];
            const tower = root.findNode(index, self.root) orelse @panic("index out of bounds");
            std.debug.print("tower index: {}\n", .{tower.index});
            try tower.tower[0].append(self.allocator, data);

            // _ = tower;
            // _ = data;
        }

        pub fn debug(self: *Self) void {
            std.debug.print("root: {}\n", .{self.root});
            std.debug.print("size: {}\n", .{self.size});

            var index: usize = 0;
            // the leaf lane is at the bottom of the tower
            var current: ?*Lane(item, k) = self.tower[0];
            while (current) |node| {
                std.debug.print("{}: ", .{index});
                current = node.next;
                index += 1;

                const width = node.width;
                const items = node.leafItems().?;
                for (0..width) |i| {
                    std.debug.print("{},", .{items[i]});
                }
                for (0..k - width) |_| {
                    std.debug.print("---,", .{});
                }
                std.debug.print("\n", .{});
            }
        }
    };
}
