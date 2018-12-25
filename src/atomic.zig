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

        pub fn load(self: *Self, order: AtomicOrder) T {
            return @atomicLoad(T, &self.raw, order);
        }

        pub fn store(self: *Self, new: T) void {
            _ = self.xchg(new);
        }

        pub fn xchg(self: *Self, new: T, order: AtomicOrder) T {
            return @atomicRmw(T, &self.raw, AtomicRmwOp.Xchg, new, order);
        }
    };
}