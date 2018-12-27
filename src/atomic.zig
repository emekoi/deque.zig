//  Copyright (c) 2018 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const builtin = @import("builtin");

pub fn Atomic(comptime T: type) type {
    return struct {
        const Self = @This();

        raw: T,

        pub fn init(raw: T) Self {
            return Self { .raw = raw };
        }

        pub fn load(self: *Self, comptime order: builtin.AtomicOrder) T {
            return @atomicLoad(T, &self.raw, order);
        }

        pub fn store(self: *Self, new: T, comptime order: builtin.AtomicOrder) void {
            _ = self.xchg(new, order);
        }

        pub fn xchg(self: *Self, new: T, comptime order: builtin.AtomicOrder) T {
            return @atomicRmw(T, &self.raw, builtin.AtomicRmwOp.Xchg, new, order);
        }

        fn strongestFailureOrder(comptime order: builtin.AtomicOrder) builtin.AtomicOrder {
            return switch (order) {
                builtin.AtomicOrder.Release => builtin.AtomicOrder.Monotonic,
                builtin.AtomicOrder.Monotonic => builtin.AtomicOrder.Monotonic,
                builtin.AtomicOrder.SeqCst => builtin.AtomicOrder.SeqCst,
                builtin.AtomicOrder.Acquire => builtin.AtomicOrder.Acquire,
                builtin.AtomicOrder.AcqRel => builtin.AtomicOrder.Acquire,
                else => @panic("invalid AtomicOrder"),
            };
        }

        pub fn cmpSwap(self: *Self, expected: T, new: T, comptime order: builtin.AtomicOrder) T {
            if (@cmpxchgStrong(T, &self.raw, expected, new, order, comptime strongestFailureOrder(order))) |current| {
                return current;
            } else {
                return expected;
            }
        }
    };
}
