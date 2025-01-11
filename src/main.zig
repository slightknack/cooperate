const std = @import("std");
const Alloc = std.mem.Allocator;

/// An array with a fixed maximum size, allocated up front.
/// If you fill the array with items containing pointers,
/// you are responsible for freeing those items
/// before you pop, trim, or drop the array.
fn StaticArray(comptime T: type, max: usize) type {
    return struct {
        const Self = @This();
        items: [max]T,
        len: usize,

        /// Creates a new empty `StaticArray`.
        /// Items can be accessed directly through `.items`,
        /// but care must be taken to never access items past `.len`,
        /// which may contain uninitialized memory.
        pub fn init() Self {
            return Self{ .items = undefined, .len = 0 };
        }

        /// Appends an item to the end, returning null.
        /// If full, returns the item and does not modify the `StaticArray`.
        pub fn push(self: *Self, item: T) ?T {
            if (self.len == max) return item;
            self.items[self.len] = item;
            self.len += 1;
            return null;
        }

        /// Pops an item from the end, returning the item.
        /// If empty, returns null.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }

        /// Returns the last item in the list, does not modify the list.
        /// invalidated if item popped or trimmed.
        pub fn last(self: *Self) ?T {
            if (self.len == 0) return null;
            return self.items[self.len - 1];
        }

        /// Appends as much of a slice as possible,
        /// returning a new slice with the remaining elements.
        /// If the new slice is empty, all elements were appended.
        pub fn extend(self: *Self, items: []T) []T {
            const rem = max - self.len;
            if (rem >= items.len) {
                // all items can fit inside
                const dest = &self.items[self.len .. self.len + items.len];
                std.mem.copyForwards(T, dest.*, items);
                self.len += items.len;
                return items[0..0];
            } else {
                // there are more items than remaining space
                const dest = &self.items[self.len..max];
                std.mem.copyForwards(T, dest.*, items[0..rem]);
                self.len = max;
                return items[rem..];
            }
        }

        /// Trims the array to the given length,
        /// returning a slice to the discarded items.
        /// This slice will be invalidated if the array is pushed to or extended.
        /// assumes that the new length <= current length.
        pub fn trim(self: *Self, len: usize) []T {
            std.debug.assert(self.len >= len);
            const slice = self.items[len..self.len];
            self.len = len;
            return slice;
        }
    };
}

/// A node in a stack of linked lists.
/// The bottomost list contains pointers to blocks.
/// Each block should be the size of a cache line or a page, depending on use-case.
/// Backbone of the KTable.
fn Node(comptime T: type, k: usize) type {
    return struct {
        const Self = @This();
        const Block = StaticArray(T, k);
        next: ?*Self,
        items_before: usize,
        down: union(enum) {
            layer: *Self,
            block: *Block,
        },

        /// Create and allocate a new `Node` with a given `Block`.
        /// Where the cdr of the `Node` is `end`.
        fn consBlock(
            alloc: Alloc,
            block: *Block,
            end: ?*Self,
        ) error{OutOfMemory}!*Self {
            const items_in_block = block.len;
            if (end) |node| {
                node.items_before = items_in_block;
            }
            const out = try alloc.create(Self);
            out.* = Self{
                .next = end,
                .items_before = 0,
                .down = .{ .block = block },
            };
            return out;
        }

        /// De-initializes the Node, traversing to next.
        /// If the `Node` is of variant `.block`, will also free the `Block`.
        /// If the `Node` is of variant `.layer`, will NOT traverse down and free that layer.
        /// You must free lower layers yourself.
        fn deinit(self: *Self, alloc: Alloc) void {
            var current: ?*Self = self;
            while (current) |node| {
                const next = node.next;
                switch (node.down) {
                    .block => |block| alloc.destroy(block),
                    .layer => {},
                }
                alloc.destroy(node);
                current = next;
            }
        }

        /// Create and allocate a single Block from a small slice.
        /// Caller must guarantee that slice.len <= k.
        fn blockFromSmallSlice(
            alloc: Alloc,
            slice: []T,
        ) error{OutOfMemory}!*Block {
            var block = try alloc.create(Block);
            block.* = Block.init();
            const extra = block.extend(slice);
            std.debug.assert(extra.len == 0);
            return block;
        }

        /// Given a slice, allocates a series of blocks.
        /// If slice.len is not a multiple of k,
        /// the last block will be partially full.
        /// If the slice is empty, this method will return end.
        fn blocksFromSlice(
            alloc: Alloc,
            slice: []T,
            end: ?*Self,
        ) error{OutOfMemory}!?*Self {
            // figure out how many blocks we will need
            const rem = @mod(slice.len, k);
            const last_block_end = slice.len - rem;
            const num_blocks = @divExact(last_block_end, k);

            // create last partially-full node
            var out: ?*Self = end;
            if (rem != 0) {
                const last_block = try blockFromSmallSlice(alloc, slice[last_block_end..]);
                out = try consBlock(alloc, last_block, out);
            }

            // fill list backwards
            for (0..num_blocks) |i| {
                const block_start = last_block_end - k * i - k;
                const block = try blockFromSmallSlice(alloc, slice[block_start .. block_start + k]);
                out = try consBlock(alloc, block, out);
            }

            // return the head of the list
            return out;
        }

        /// Prints out the list, with one node per line.
        /// If there is a block, prints the content of the block.
        fn debug(self: *Self) void {
            var current: ?*Self = self;
            while (current) |node| {
                std.debug.print("node: .items_before = {}, ", .{node.items_before});
                switch (node.down) {
                    .block => |block| std.debug.print(".block = '{s}'\n", .{block.items}),
                    .layer => std.debug.print(".layer\n", .{}),
                }
                current = node.next;
            }
            std.debug.print("null\n", .{});
        }
    };
}

/// An ordered table with log(n) index lookup
/// and constant-time insertion after index lookup.
/// Basically a Skip List pretending to be a really bad BTree without keys.
///
/// We support three key operations:
/// - `insert(index, slice)`
/// - `delete(start, end)`
/// - `get(start, end, buffer) bytes_written`
fn KTable(comptime T: type, k: usize) type {
    return struct {
        const layers = 25;
        const Self = @This();
        const Layer = Node(T, k);
        const Layers = [layers]?*Layer;

        layers: Layers,
        alloc: Alloc,

        /// Create a new empty table.
        fn init(alloc: Alloc) Self {
            return Self{
                .layers = [_]?*Layer{null} ** layers,
                .alloc = alloc,
            };
        }

        // todo: finish implementing this
        // todo: once this is working, it can be generalized to any layers, e.g. from index.
        // todo: with a small addition to handle the first block, this method can be the backbone for insertion
        fn appendFront(self: *Self, slice: []T) error{OutOfMemory}!void {
            // we build the blocks we will be appending
            const blocks = try Layer.blocksFromSlice(self.alloc, slice, self.layers[0]);
            // we go through each block and build a tower
            _ = blocks;
            // we link the towers together and ensure that items_before is conserved in each layer.
        }

        /// The famous log(n) index lookup.
        /// Returns a slice of layers, which can be used for inserting a new node.
        /// The bottom-most layer (at index 0) contains a block
        fn index(self: *Self, at: usize) Layers {
            _ = self;
            _ = at;
        }

        /// get a range of the KTable as a slice.
        /// Walks the kTable and writes to a buffer.
        fn get(
            self: *Self,
            start: usize,
            end: usize,
            buffer: []T,
        ) usize {
            std.debug.assert(start <= end);
            const to_read = end - start;
            _ = self;
            _ = buffer;
            _ = to_read;
        }
    };
}

pub fn main() !void {
    std.debug.print("Nice work!\n", .{});
}

test "StaticArray basic ops" {
    var array = StaticArray(u8, 25).init();
    var hello: [33]u8 = "hello my dear friend how are you?".*;
    const out = array.extend(&hello);
    std.debug.print("not appended: '{s}'\n", .{out});
    const trimmed = array.trim(5);
    std.debug.print("text trimmed: '{s}'\n", .{trimmed});
    try std.testing.expectEqualSlices(u8, " my dear friend how ", trimmed);
}

test "List make a bunch of blocks" {
    const alloc = std.testing.allocator;
    var gold: [102]u8 = "Nature's first green is gold, Her hardest hue to hold. Her early leaf's a flower; But only so an hour.".*;
    const node = try Node(u8, 25).blocksFromSlice(alloc, &gold, null) orelse @panic("gold is not empty!");
    defer node.deinit(alloc);
    node.debug();
}

test "KTable init" {
    const alloc = std.testing.allocator;
    const table = KTable(u8, 25).init(alloc);
    _ = table;
}
