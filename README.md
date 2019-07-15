# *deque.zig*

a lock free chase-lev deque for zig.



## usage
```zig
const std = @import("std");
const deque = @import("deque");

const AMOUNT: usize = 100000;

const Task = struct {
    const Self = @This();
    stealer: deque.Stealer(usize, 32),
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

pub fn main() !void {
    var slice = try std.heap.direct_allocator.alloc(u8, 1 << 24);
    var fba = std.heap.ThreadSafeFixedBufferAllocator.init(slice);
    var alloc = &fba.allocator;

    var d = try deque.Deque(usize, 32).new(alloc);
    defer d.deinit();

    var i: usize = 0;
    const worker = d.worker();
    while (i < AMOUNT) : (i += 1) {
        try worker.push(i);
    }

    var threads: [4]*std.Thread = undefined;
    var task = Task{
        .stealer = d.stealer(),
    };

    for (threads) |*thread|
        thread.* = try Thread.spawn(&task, Task.task);

    for (threads) |thread|
        thread.wait();

    task.verify();
}
```
