//  Copyright (c) 2018 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const builtin = @import("builtin");

const Atomic = @import("deque/atomic.zig").Atomic;

const mem = std.mem;

const MIN_SIZE = 32;

fn nextPowerOf2(x: usize) usize {
    if (x == 0) return 1;
    var result = x -% 1;
    result = switch (@sizeOf(usize)) {
        8 => result | (result >> 32),
        4 => result | (result >> 16),
        2 => result | (result >> 8),
        1 => result | (result >> 4),
        else => 0,
    };
    result |= (result >> 4);
    result |= (result >> 2);
    result |= (result >> 1);
    return result +% (1 + @boolToInt(x <= 0));
}

pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: *mem.Allocator,
        array: Atomic(*Buffer(T)),
        bottom: Atomic(isize),
        top: Atomic(isize),

        pub fn new(allocator: *mem.Allocator) !Self {
            const buf = try Buffer(T).new(allocator, MIN_SIZE);
            return Self{
                .array = Atomic(*Buffer(T)).init(buf),
                .bottom = Atomic(isize).init(0),
                .top = Atomic(isize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.array.load(.Monotonic).deinit();
        }

        pub fn worker(self: *Self) Worker(T) {
            return Worker(T){
                .deque = self,
            };
        }

        pub fn stealer(self: *Self) Stealer(T) {
            return Stealer(T){
                .deque = self,
            };
        }

        fn push(self: *Self, item: T) !void {
            const bottom = self.bottom.load(.Monotonic);
            const top = self.top.load(.Acquire);
            var array = self.array.load(.Monotonic);

            const size = bottom -% top;
            if (size == array.count()) {
                array = try array.grow(bottom, top);
                self.array.store(array, .Release);
            }

            array.put(bottom, item);
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

            const a = self.array.load(.Monotonic);
            var data = a.get(bottom);

            if (size != 0) {
                return data;
            }

            if (self.top.cmpSwap(top, top +% 1, .SeqCst) == top) {
                self.bottom.store(top +% 1, .Monotonic);
                return data;
            } else {
                self.bottom.store(top +% 1, .Monotonic);
                return null;
            }
        }

        pub fn steal(self: *Self) Stolen(T) {
            const top = self.top.load(.Acquire);
            @fence(.SeqCst);
            const bottom = self.bottom.load(.Acquire);

            const size = bottom -% top;
            if (size <= 0) {
                return Stolen(T){ .Empty = {} };
            }

            const a = self.array.load(.Acquire);
            const data = a.get(top);

            if (self.top.cmpSwap(top, top +% 1, .SeqCst) == top) {
                return Stolen(T){ .Data = data };
            } else {
                return Stolen(T){ .Abort = {} };
            }
        }
    };
}

pub fn Worker(comptime T: type) type {
    return struct {
        const Self = @This();

        deque: *Deque(T),

        pub fn push(self: *const Self, item: T) !void {
            try self.deque.push(item);
        }

        pub fn pop(self: *const Self, item: T) ?T {
            return self.deque.pop();
        }
    };
}

pub fn Stealer(comptime T: type) type {
    return struct {
        const Self = @This();

        deque: *Deque(T),

        pub fn steal(self: *const Self) Stolen(T) {
            return self.deque.steal();
        }
    };
}

pub fn Stolen(comptime T: type) type {
    return union(enum) {
        Empty: void,
        Abort: void,
        Data: T,
    };
}

fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: *mem.Allocator,
        prev: ?*Buffer(T),
        storage: []T,

        fn new(allocator: *mem.Allocator, size: usize) !*Self {
            var self = try allocator.createOne(Self);
            self.storage = try allocator.alloc(T, size);
            self.allocator = allocator;
            self.prev = null;
            return self;
        }

        fn deinit(self: *Self) void {
            std.debug.warn("{}", self.storage.len);
            self.allocator.free(self.storage);
            if (self.prev) |buf| {
                std.debug.warn(" + ");
                buf.deinit();
            } else {
                std.debug.warn("\n");
            }
            self.allocator.destroy(self);
        }

        fn count(self: *const Self) isize {
            return @intCast(isize, self.storage.len);
        }

        fn mask(self: *const Self) usize {
            return @intCast(usize, self.storage.len -% 1);
        }

        fn elem(self: *const Self, i: isize) *T {
            return &self.storage[@bitCast(usize, i) & self.mask()];
        }

        fn get(self: *const Self, i: isize) T {
            return self.elem(i).*;
        }

        fn put(self: *const Self, i: isize, item: T) void {
            self.elem(i).* = item;
        }

        fn grow(self: *Self, bottom: isize, top: isize) !*Self {
            var buf = try Self.new(self.allocator, self.storage.len * 2);
            var i = top;
            while (i != bottom) : (i +%= 1) {
                buf.put(i, self.get(i));
            }
            buf.prev = self;
            return buf;
        }
    };
}

const AMT: usize = 10000;
const AMT_size: usize = AMT * 2;
var static_memory = []u8{0} ** (@sizeOf(usize) * AMT_size);

test "steal and push" {
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(static_memory[0..]);
    var a = &fba.allocator;

    var deque = try Deque(usize).new(a);
    defer deque.deinit();

    const thread = try std.os.spawnThread(deque.stealer(), worker_stealpush);

    var i: usize = 0;
    const worker = deque.worker();
    while (i < AMT) : (i += 1) {
        try worker.push(i);
    }

    thread.wait();
}

fn worker_stealpush(stealer: Stealer(usize)) void {
    var left: usize = AMT;
    while (left > 0) {
        switch (stealer.steal()) {
            Stolen(usize).Data => |i| {
                std.testing.expectEqual(i + left, AMT);
                left -= 1;
            },
            Stolen(usize).Empty => break,
            Stolen(usize).Abort => {},
        }
    }
}

// test "multiple threads" {
//     var fba = std.heap.ThreadSafeFixedBufferAllocator.init(static_memory[0..]);
//     var a = &fba.allocator;
//     var deque = try Deque(usize).withCapacity(a, AMT);
//     defer deque.deinit();
//     var threads: [2]*std.os.Thread = undefined;
//     for (threads) |*t| {
//         t.* = try std.os.spawnThread(deque.stealer(), worker_multi);
//     }
//     var i: usize = 0;
//     const worker = deque.worker();
//     while (i < AMT) : (i += 1) {
//         worker.push(i) catch |_| {
//             std.debug.warn("\n{}\n", i);
//             unreachable;
//         };
//     }
//     for (threads) |t| {
//         t.wait();
//     }
// }

// fn worker_multi(stealer: Stealer(usize)) void {
//     while (true) {
//         switch (stealer.steal()) {
//             Stolen(usize).Data => |i| {
//                 // std.debug.warn("thread {}: {}\n", std.os.Thread.getCurrentId(), i);
//             },
//             Stolen(usize).Empty => {
//                 break;
//             },
//             Stolen(usize).Abort => {},
//         }
//     }
// }
