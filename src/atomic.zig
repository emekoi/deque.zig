//  Copyright (c) 2020 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const builtin = @import("builtin");

pub const AtomicOrder = builtin.AtomicOrder;
// const AtomicRmwOp = builtin.AtomicRmwOp;

pub fn Atomic(comptime T: type) type {
    return struct {
        const Self = @This();

        raw: T,

        pub fn init(raw: T) Self {
            return Self{ .raw = raw };
        }

        pub fn load(self: *Self, comptime order: AtomicOrder) T {
            return @atomicLoad(T, &self.raw, order);
        }

        pub fn store(self: *Self, new: T, comptime order: AtomicOrder) void {
            @atomicStore(T, &self.raw, new, order);
        }

        pub fn xchg(self: *Self, new: T, comptime order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, .Xchg, new, order);
        }

        fn strongestFailureOrder(comptime order: AtomicOrder) AtomicOrder {
            return switch (order) {
                .Release => .Monotonic,
                .Monotonic => .Monotonic,
                .SeqCst => .SeqCst,
                .Acquire => .Acquire,
                .AcqRel => .Acquire,
                else => @panic("invalid AtomicOrder"),
            };
        }

        pub fn cmpSwap(self: *Self, expected: T, new: T, comptime order: AtomicOrder) T {
            if (@cmpxchgStrong(T, &self.raw, expected, new, order, comptime strongestFailureOrder(order))) |current| {
                return current;
            } else {
                return expected;
            }
        }
    };
}
