//  Copyright (c) 2018 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const builtin = @import("builtin");

const Atomic = @import("atomic.zig").Atomic;
const SegmentedList = std.SegmentedList;
const Allocator = std.mem.Allocator;

pub fn Node(comptime T: type) type {
    return struct {
        data: T = undefined,
        next: ?*Node(T) = null,
    };
}

pub fn Deque(comptime T: type, comptime P: usize) type {
    return struct {
        const Self = @This();
        const List = SegmentedList(Node(T), P);

        allocator: *Allocator,
        storage: Atomic(*List),

        free_list: Atomic(?*Node(T)),
        in_use_list: Atomic(?*Node(T)),

        pub fn new(allocator: *Allocator) !Self {
            var storage = try allocator.create(List);
            storage.* = List.init(allocator);
            return Self{
                .storage = Atomic(*List).init(storage),
                .free_list = Atomic(?*Node(T)).init(null),
                .in_use_list = Atomic(?*Node(T)).init(null),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.storage.load(.Monotonic).deinit();
        }

        pub fn worker(self: *Self) Worker(T, P) {
            return Worker(T, P){
                .deque = self,
            };
        }

        pub fn stealer(self: *Self) Stealer(T, P) {
            return Stealer(T, P){
                .deque = self,
            };
        }

        fn push(self: *Self, item: T) !void {
            var in_use_list = self.in_use_list.load(.Monotonic);
            var free_list = self.free_list.load(.Monotonic);

            if (free_list) |node| {
                defer self.free_list.store(free_list, .Release);
                defer self.in_use_list.store(in_use_list, .Release);

                // remove from free list
                free_list = node.next;
                node.data = item;

                // append to list of nodes in-use
                in_use_list.?.next = node;
                return;
            }

            defer self.in_use_list.store(in_use_list, .Release);

            var storage = self.storage.load(.Monotonic);
            var node = try storage.addOne();
            node.data = item;

            if (in_use_list) |list| {
                list.next = node;
            } else {
                in_use_list = node;
            }
        }

        fn pop(self: *Self) ?T {
            var in_use_list = self.in_use_list.load(.Monotonic);

            if (in_use_list) |list| {
                if (self.in_use_list.cmpSwapStrong(list, list.next, .SeqCst) == list) {
                    var free_list = self.free_list.load(.Monotonic);
                    defer self.free_list.store(free_list, .Release);

                    const data = list.data;

                    list.next = free_list;
                    free_list = list;

                    return data;
                } else {
                    // value was stolen
                    return null;
                }
            } else {
                // list is empty
                return null;
            }
        }

        pub fn steal(self: *Self) ?T {
            while (true) {
                var in_use_list = self.in_use_list.load(.Acquire);

                if (in_use_list) |list| {
                    if (self.in_use_list.cmpSwapWeak(list, list.next, .SeqCst) == list) {
                        var free_list = self.free_list.load(.Acquire);
                        defer self.free_list.store(free_list, .Release);

                        const data = list.data;

                        list.next = free_list;
                        free_list = list;

                        return data;
                    } else {
                        // value was stolen
                        continue;
                    }
                } else {
                    // list is empty
                    return null;
                }
            }
        }
    };
}

pub fn Worker(comptime T: type, comptime P: usize) type {
    return struct {
        const Self = @This();

        deque: *Deque(T, P),

        pub fn push(self: *const Self, item: T) !void {
            try self.deque.push(item);
        }

        pub fn pop(self: *const Self, item: T) ?T {
            return self.deque.pop();
        }
    };
}

pub fn Stealer(comptime T: type, comptime P: usize) type {
    return struct {
        const Self = @This();

        deque: *Deque(T, P),

        pub fn steal(self: *const Self) ?T {
            return self.deque.steal();
        }
    };
}

const Thread = std.Thread;
const AMOUNT: usize = 10000;

test "single-threaded" {
    const S = struct {
        fn task(stealer: Stealer(usize, 32)) void {
            var left: usize = AMOUNT;
            while (stealer.steal()) |i| {
                // std.testing.expectEqual(i + left, AMOUNT);
                // std.testing.expectEqual(AMOUNT - i, left);
                std.debug.warn("{}\n", i);
                left -= 1;
            }
            std.testing.expectEqual(usize(0), left);
        }
    };

    var slice = try std.heap.direct_allocator.alloc(u8, 1 << 24);
    defer std.heap.direct_allocator.free(slice);
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(slice);
    var alloc = &fba.allocator;

    var deque = try Deque(usize, 32).new(alloc);
    defer deque.deinit();

    var i: usize = 0;
    const worker = deque.worker();
    while (i < AMOUNT) : (i += 1) {
        try worker.push(i);
    }

    var p = deque.in_use_list.load(.Acquire);
    std.debug.warn("hello\n");

    while (p) |pointer| : (p = pointer.next) {
        std.debug.warn("{}\n", pointer.data);
    }

    std.debug.warn("hello\n");

    // const thread = try Thread.spawn(deque.stealer(), S.task);
    // thread.wait();
}

test "single-threaded-no-prealloc" {
    const S = struct {
        fn task(stealer: Stealer(usize, 0)) void {
            var left: usize = AMOUNT;
            while (stealer.steal()) |i| {
                std.testing.expectEqual(i + left, AMOUNT);
                std.testing.expectEqual(AMOUNT - i, left);
                left -= 1;
            }
            std.testing.expectEqual(usize(0), left);
        }
    };

    var slice = try std.heap.direct_allocator.alloc(u8, 1 << 24);
    defer std.heap.direct_allocator.free(slice);
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(slice);
    var alloc = &fba.allocator;

    var deque = try Deque(usize, 0).new(alloc);
    defer deque.deinit();

    var i: usize = 0;
    const worker = deque.worker();
    while (i < AMOUNT) : (i += 1) {
        try worker.push(i);
    }

    const thread = try Thread.spawn(deque.stealer(), S.task);
    thread.wait();
}

test "multiple-threads" {
    const S = struct {
        const Self = @This();
        stealer: Stealer(usize, 32),
        data: [AMOUNT]usize = [_]usize{0} ** AMOUNT,

        fn task(self: *Self) void {
            while (self.stealer.steal()) |i| {
                defer std.testing.expectEqual(i, self.data[i]);
                self.data[i] += i;
            }
        }

        fn verify(self: Self) void {
            for (self.data[0..]) |*i, idx| {
                std.testing.expectEqual(idx, i.*);
            }
        }
    };

    var slice = try std.heap.direct_allocator.alloc(u8, 1 << 24);
    defer std.heap.direct_allocator.free(slice);
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(slice);
    var alloc = &fba.allocator;

    var deque = try Deque(usize, 32).new(alloc);
    defer deque.deinit();

    var i: usize = 0;
    const worker = deque.worker();
    while (i < AMOUNT) : (i += 1) {
        try worker.push(i);
    }

    var threads: [4]*std.Thread = undefined;
    var ctx = S{
        .stealer = deque.stealer(),
    };

    for (threads) |*t| {
        t.* = try Thread.spawn(&ctx, S.task);
    }

    for (threads) |t| t.wait();
    ctx.verify();
}

test "multiple-threads-no-prealloc" {
    const S = struct {
        const Self = @This();
        stealer: Stealer(usize, 0),
        data: [AMOUNT]usize = [_]usize{0} ** AMOUNT,

        fn task(self: *Self) void {
            while (self.stealer.steal()) |i| {
                defer std.testing.expectEqual(i, self.data[i]);
                self.data[i] += i;
            }
        }

        fn verify(self: Self) void {
            for (self.data[0..]) |*i, idx| {
                std.testing.expectEqual(idx, i.*);
            }
        }
    };

    var slice = try std.heap.direct_allocator.alloc(u8, 1 << 24);
    defer std.heap.direct_allocator.free(slice);
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(slice);
    var alloc = &fba.allocator;

    var deque = try Deque(usize, 0).new(alloc);
    defer deque.deinit();

    var i: usize = 0;
    const worker = deque.worker();
    while (i < AMOUNT) : (i += 1) {
        try worker.push(i);
    }

    var threads: [4]*std.Thread = undefined;
    var ctx = S{
        .stealer = deque.stealer(),
    };

    for (threads) |*t| {
        t.* = try Thread.spawn(&ctx, S.task);
    }

    for (threads) |t| t.wait();
    ctx.verify();
}
