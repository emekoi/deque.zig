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
            var buffer: ?*Self = self;
            while (buffer) |buf| {
                self.allocator.free(buf.storage);
                buffer = buf.prev;
                self.allocator.destroy(buf);
            }
        }

        fn count(self: *const Self) isize {
            return @intCast(isize, self.storage.len);
        }

        fn mask(self: *const Self) usize {
            return @intCast(usize, self.storage.len) -% 1;
        }

        fn elem(self: *const Self, i: isize) *T {
            return &self.storage[@bitCast(usize, i) & self.mask()];
        }

        fn get(self: *const Self, i: isize) T {
            return self.elem(i).*;
        }

        fn set(self: *const Self, i: isize, item: T) void {
            self.elem(i).* = item;
        }

        fn grow(self: *Self, b: isize, t: isize) !*Self {
            var buf = try Self.new(self.allocator, self.storage.len * 2);
            var i = t;
            while (i != b) : (i +%= 1) {
                buf.set(i, self.get(i));
            }
            buf.prev = self;
            return buf;
        }
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
                .array = Atomic(*Buffer(T)).init(try Buffer(T).new(allocator, MIN_SIZE)),
                .bottom = Atomic(isize).init(0),
                .top = Atomic(isize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.array.load(AtomicOrder.Monotonic).deinit();
        }

        fn push(self: *Self, item: T) !void {
            const b = self.bottom.load(AtomicOrder.Monotonic);
            const t = self.top.load(AtomicOrder.Acquire);
            var a = self.array.load(AtomicOrder.Monotonic);

            const size = b -% t;
            if (size == a.count()) {
                a = try a.grow(b, t);
                self.array.store(a, AtomicOrder.Release);
            }

            a.set(b, item);
            @fence(AtomicOrder.Release);
            self.bottom.store(b + 1, AtomicOrder.Monotonic);
        }

        fn pop(self: *Self) ?T {
            var b = self.bottom.load(AtomicOrder.Monotonic);
            var t = self.top.load(AtomicOrder.Monotonic);

            if (b -% t <= 0) {
                return null;
            }

            b -%= 1;
            self.bottom.store(b, AtomicOrder.Monotonic);
            @fence(AtomicOrder.SeqCst);

            t = self.top.load(AtomicOrder.Monotonic);

            const size = b -% t;
            if (size < 0) {
                self.bottom.store(b +% 1, AtomicOrder.Monotonic);
                return null;
            }

            const a = self.array.load(AtomicOrder.Monotonic);
            var data = a.get(b);

            if (size != 0) {
                return data;
            }

            if (self.top.cmpxchgStrong(t, t +% 1, AtomicOrder.SeqCst)) |old| {
                if (t == old) {
                    self.bottom.store(t +% 1, AtomicOrder.Monotonic);
                    return data;
                }
            } else {
                self.bottom.store(t +% 1, AtomicOrder.Monotonic);
                return null;
            }
        }

        pub fn steal(self: *Self) Stolen(T) {
            const t = self.top.load(AtomicOrder.Acquire);
            @fence(AtomicOrder.SeqCst);
            const b = self.bottom.load(AtomicOrder.Acquire);

            const size = b -% t;
            if (size <= 0) {
                return Stolen(T) { .Empty = {} };
            }

            const a = self.array.load(AtomicOrder.Acquire);
            const data = a.get(t);
            
            if (self.top.cmpxchgStrong(t, t +% 1, AtomicOrder.SeqCst)) |old| {
                if (t == old) {
                    return Stolen(T) { .Data = data };
                }
            }

            return Stolen(T) { .Abort = {} };
        }

        pub fn worker(self: *Self) Worker(T) {
            return Worker(T) {
                .deque = self,
            };
        }

        pub fn stealer(self: *Self) Stealer(T) {
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
            try self.deque.push(item);
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

const AMT: usize = 100000;

test "stealpush" {    
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var plenty_of_memory = try direct_allocator.allocator.alloc(u8, 500 * 1024);
    defer direct_allocator.allocator.free(plenty_of_memory);

    var fixed_buffer_allocator = std.heap.ThreadSafeFixedBufferAllocator.init(plenty_of_memory);
    var a = &fixed_buffer_allocator.allocator;

    var deque = try Deque(isize).new(a);
    defer deque.deinit();

    const worker = deque.worker();
    const stealer = deque.stealer();

    const thread = try std.os.spawnThread(&stealer, worker_stealpush);

    var i: usize = 0;
    while (i < AMT) : (i += 1) {
        try worker.push(1);
    }

    thread.wait();
}

fn worker_stealpush(stealer: *const Stealer(isize)) void {
    var left = AMT;
    while (left > 0) {
        switch (stealer.steal()) {
            Stolen(isize).Data => |i| {
                std.debug.assert(i == 1);
                std.debug.warn("{}\n", i);
                left -= 1;
            },
            Stolen(isize).Abort, Stolen(isize).Empty => {
                
            }
        }
    }
}