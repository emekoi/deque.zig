//  Copyright (c) 2020 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

usingnamespace @import("deque");
const std = @import("std");

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
            std.testing.expectEqual(@as(usize, 0), left);
        }
    };

    var slice = try std.heap.page_allocator.alloc(u8, 1 << 24);
    defer std.heap.page_allocator.free(slice);
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
            std.testing.expectEqual(@as(usize, 0), left);
        }
    };

    var slice = try std.heap.page_allocator.alloc(u8, 1 << 24);
    defer std.heap.page_allocator.free(slice);
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

    var slice = try std.heap.page_allocator.alloc(u8, 1 << 24);
    defer std.heap.page_allocator.free(slice);
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

    var slice = try std.heap.page_allocator.alloc(u8, 1 << 24);
    defer std.heap.page_allocator.free(slice);
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
