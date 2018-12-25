//  Copyright (c) 2018 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const builtin = @import("builtin");

const Atomic = @import("atomic.zig").Atomic;
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const mem = std.mem;

const MIN_SIZE = 32;

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        storage: []T,
        prev: ?*Buffer(T),
    };
}

pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: *mem.Allocator,
        array: Atomic(*Buffer(T)),
        bottom: Atomic(isize),
        top: Atomic(isize),

        pub fn new(allocator: *mem.Allocator) !Self {
            return Self {
                .array = try Buffer.new(allocator, MIN_SIZE),
                .allocator = allocator,
                .bottom = Atomic.init(0),
                .top = Atomic.init(0),
            };
        }

        pub fn deinit(self: *Self) void {

        }

        fn push(self: *const Self, item: T) !void {
            const b = @atomicLoad(isize, &self.bottom, AtomicOrder.Relaxed);
            const t = @atomicLoad(isize, &self.top, AtomicOrder.Acquire);
            var a = @atomicLoad(*Buffer(T), &self.array, AtomicOrder.Relaxed);

            const size = b -% t;
            if (size == a.len) {
                a = try a.grow(b, t);
                _ = @atomicRmw(*Buffer(T), &self.array, AtomicRmwOp.Xchg, a, AtomicOrder.Relaxed);
            }

            a.put(b, item);
            @fence(AtomicOrder.Release);
            _ = @atomicRmw(isize, &self.bottom, AtomicRmwOp.Xchg, b + 1, AtomicOrder.Relaxed);
        }

        fn pop(self: *const Self) ?T {
            const b = @atomicLoad(isize, &self.bottom, AtomicOrder.Relaxed);
        }

        pub fn worker(self: *const Self) Worker(T) {
            return Worker(T) {
                .deque = self,
            };
        }

        pub fn stealer(self: *const Self) Stealer(T) {
            return Stealer(T) {
                .deque = self,
            };
        }
    };
}

pub fn Worker(comptime T: type) type {
    return struct {
        const Self = @This();

        deque: *Deque(T),

        pub fn push(self: *const Self, item: T) !void {
            try self.deque.push(T);
        }

        pub fn pop(self: *const Self, item: T) ?T {
            return self.deque.pop(T);
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