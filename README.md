# *deque.zig*

a lock free chase-lev deque for zig.



## usage
```
const std = @import("std");
const deque = @import("deque");

const assert = std.debug.assert;
const heap = std.heap;
const os = std.os;

const AMT: usize = 100000;
var static_memory = []u8{0} ** (@sizeOf(usize) * AMT * 2);

pub fn main() !void {
    var fba = heap.ThreadSafeFixedBufferAllocator.init(static_memory[0..]);
    var allocator = &fba.allocator;

    var d = try deque.Deque(usize).withCapacity(allocator, AMT);
    defer d.deinit();

    const thread = try os.spawnThread(d.stealer(), worker);

    var i: usize = 0;
    const worker = d.worker();
    while (i < AMT) : (i += 1) {
        try worker.push(i);
    }

    thread.wait();
}

fn worker(stealer: deque.Stealer(usize)) void {
    var left: usize = AMT;
    while (left > 0) {
        switch (stealer.steal()) {
            deque.Stolen(usize).Data => |i| {
                std.debug.assert(i + left == AMT);
                left -= 1;
            },
            deque.Stolen(usize).Empty => break,
            deque.Stolen(usize).Abort => {},
        }
    }
}
```
