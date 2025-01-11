const std = @import("std");
const Alloc = std.mem.Allocator;
const assert = std.debug.assert;

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
            assert(self.len >= len);
            const slice = self.items[len..self.len];
            self.len = len;
            return slice;
        }
    };
}

/// A node in a stack of linked lists.
/// The bottommost list contains pointers to blocks.
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
            assert(extra.len == 0);
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

        alloc: Alloc,
        // todo: replace layers and height with StaticArray, that's why you wrote it
        // layers[0] contains blocks
        layers: Layers,
        // height is the index of the first null layer, from layers[0]
        height: usize,
        // len is the number of items. Not to be confused with the number of blocks.
        len: usize,

        /// Create a new empty table.
        fn init(alloc: Alloc) Self {
            return Self{
                .alloc = alloc,
                .layers = [_]?*Layer{null} ** layers,
                .height = 0,
                .len = 0,
            };
        }

        /// Insert the given slice at the given index.
        /// The index lookup is log(n). Insertion is linear in the size of the slice.
        /// This method is like the whole point of the KTable,
        /// arbitrary indexed insertion with good asymptotics.
        fn insert(self: *Self, at: usize, slice: []T) error{OutOfMemory}!void {
            // a bookmark is a stack of layers
            // find the last node at each layer before the point of insertion
            // this is probabilistically log(n)
            const bookmark = self.index(at);

            // try writing the slice into the space of the last block
            // if bookmark[0] is empty it means there are no blocks allocated yet, which is fine.
            if (bookmark[0]) |node| {
                // const block = node.down.block;
                //todo
                _ = node;
            }

            // build the blocks we will be appending
            // this is linear with respect to the size of the slice
            const blocks = try Layer.blocksFromSlice(self.alloc, slice, self.layers[0]);

            // we go through each block and build a tower
            _ = blocks;
            // we link the towers together and ensure that items_before is conserved in each layer
        }

        // bookmark must by an array of non-null Layers,
        // followed by only null Layers.
        // This method will follow the pointer of each layer,
        // and update the next node with the number of added elements.
        fn reIndex(bookmark: Layers, added: usize) void {
            for (0..k) |i| {
                const node = bookmark[i] orelse break;
                const next = node.next orelse continue;
                next.items_before += added;
            }
        }

        /// Famous log(n) index lookup.
        /// Returns a slice of layers, which can be used for inserting a new node.
        /// The bottom-most layer (at index 0) will contain a block if the KTable is not empty.
        /// The index we are looking for is guaranteed to be in or at the end of the block.
        /// We return the index of the first item in the block (`.block_index`).
        /// This can be subtracted from at to determine
        /// the relative offset of the item we are looking for within the block.
        fn index(self: *Self, at: usize) struct {
            .layers = Layers,
            .height = usize,
            .block_index = usize,
        } {
            // in at == len, this is the same as pushing to the end
            assert(at <= self.len);

            // to get to a good place, we need to start in a good place
            // height is the first non-null block, we will start there
            const bookmark: Layers = [_]?*Layer{null} ** layers;
            if (self.height == 0) return .{
                .layers = bookmark,
                .height = 0,
                .block_index = 0,
            };
            var layer: usize = self.height - 1;

            // now we slide down the spine of self.layers,
            // trying to find the topmost block still before our target index
            // if I am thinking about this correctly,
            // if we are respecting invariants,
            // we should never hit the layer == 0 case without terminating
            // of course I should test this further
            while (self.layers[layer].?.items_before >= at) layer -= 1;

            // now we have the first item in our bookmark, let's write it
            // height is the number of layers in the bookmark, that's why we add 1
            // from this point onwards we traverse pointers and don't need self.layers
            bookmark[layer] = self.layers[layer];
            const height = layer + 1;

            // this is the important part
            // we try skipping forward, and if that doesn't work, drop down a level
            var seen = bookmark[layer].?.items_before;
            while (true) {
                // trust me bro
                var go_down = true;
                if (bookmark[layer].?.next) |next| {
                    go_down = seen + next.items_before >= at;
                }

                // okay, you don't need to trust me
                // to clean up the logic a bit,
                // we figure out what we need to do
                // and then we do it.
                // by default we want to go down
                // but if there's a node after,
                // we might want to go forwards instead
                // so we check if that node is a good idea to go to before going there
                // and once we know what to do, we do it.
                if (go_down) {
                    switch (bookmark[layer].?.down) {
                        .layer => |node| {
                            layer -= 1;
                            bookmark[layer] = node;
                        },
                        // we are at the bottom, what else is there to do?
                        .block => break,
                    }
                } else {
                    // if we can't go down, go forward!
                    // next is guaranteed to not be null, because we checked earlier
                    // I told you you needed to trust me
                    const next = bookmark[layer].?.next.?;
                    bookmark[layer] = next;
                    seen += next.items_before;
                }
            }

            // Isn't it so satisfying when it all threads together so nicely?
            return .{
                .layers = bookmark,
                .height = height,
                .block_index = seen,
            };
        }

        /// Get a range of the KTable as a slice.
        /// Walks the kTable and writes to a buffer.
        /// Returns the number of items written.
        fn get(
            self: *Self,
            start: usize,
            end: usize,
            buffer: []T,
        ) usize {
            assert(start <= end);
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
