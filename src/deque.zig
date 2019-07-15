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

pub fn Deque(comptime T: type, comptime P: usize) type {
    return struct {
        const Self = @This();
        const List = SegmentedList(T, P);

        allocator: *Allocator,
        list: Atomic(*List),
        bottom: Atomic(isize),
        top: Atomic(isize),

        pub fn new(allocator: *Allocator) !Self {
            var list = try allocator.create(List);
            list.* = List.init(allocator);
            return Self{
                .list = Atomic(*List).init(list),
                .bottom = Atomic(isize).init(0),
                .top = Atomic(isize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.list.load(.Monotonic).deinit();
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
            const bottom = self.bottom.load(.Monotonic);
            var list = self.list.load(.Monotonic);

            try list.push(item);
            @fence(.Release);
            self.bottom.store(bottom +% 1, .Monotonic);
        }

        fn pop(self: *Self) ?T {
            var bottom = self.bottom.load(.Monotonic);
            var top = self.top.load(.Monotonic);

            if (bottom -% top <= 0) {
                return null;
            }

            bottom -%= 1;
            self.bottom.store(bottom, .Monotonic);
            @fence(.SeqCst);

            top = self.top.load(.Monotonic);

            const size = bottom -% top;
            if (size < 0) {
                self.bottom.store(bottom +% 1, .Monotonic);
                return null;
            }

            const list = self.list.load(.Monotonic);
            var data = list.at(bottom);

            if (size != 0) {
                return data.*;
            }

            if (self.top.cmpSwap(top, top +% 1, .SeqCst) == top) {
                self.bottom.store(top +% 1, .Monotonic);
                return data.*;
            } else {
                self.bottom.store(top +% 1, .Monotonic);
                return null;
            }
        }

        pub fn steal(self: *Self) ?T {
            while (true) {
                const top = self.top.load(.Acquire);
                @fence(.SeqCst);
                const bottom = self.bottom.load(.Acquire);

                const size = bottom -% top;
                if (size <= 0) return null;

                const list = self.list.load(.Acquire);
                const data = list.at(@intCast(usize, top));

                if (self.top.cmpSwap(top, top +% 1, .SeqCst) == top) {
                    return data.*;
                } else {
                    continue;
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
                std.testing.expectEqual(i + left, AMOUNT);
                std.testing.expectEqual(AMOUNT - i, left);
                left -= 1;
            }
            std.testing.expectEqual(usize(0), left);
        }
    };

    var slice = try std.heap.direct_allocator.alloc(u8, 1 << 24);
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(slice);
    var alloc = &fba.allocator;

    var deque = try Deque(usize, 32).new(alloc);
    defer deque.deinit();

    var i: usize = 0;
    const worker = deque.worker();
    while (i < AMOUNT) : (i += 1) {
        try worker.push(i);
    }

    const thread = try Thread.spawn(deque.stealer(), S.task);
    thread.wait();
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
