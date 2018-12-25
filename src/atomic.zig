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

        pub fn cmpxchgStrong(self: *Self, old: T, new: T, comptime order: builtin.AtomicOrder) ?T {
            return @cmpxchgStrong(T, &self.raw, old, new, order, order);
        }
    };
}