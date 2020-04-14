const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("deque", "src/deque.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("test/test.zig");
    main_tests.addPackagePath("deque", "src/deque.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "run library tests");
    test_step.dependOn(&main_tests.step);
}
