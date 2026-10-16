//! Grain OS build graph.
//!
//!   zig build              build the Caravan kernel image (zig-out/bin/caravan)
//!   zig build run          boot it in QEMU (riscv64 virt, serial on stdio)
//!   zig build test         host unit tests for the portable kernel core
//!   zig build qemu-test    boot in QEMU deterministically (-icount) and check the self-tests
//!   zig build debug        boot halted with a GDB stub on :1234 (see docs/TESTING.md)
const std = @import("std");

const Board = enum { qemu_virt, generic_sbi };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const qemu_timeout = b.option([]const u8, "qemu-timeout", "Seconds before a QEMU run is killed") orelse "30";

    // The kernel never touches floating point: drop F/D so the compiler cannot
    // emit FP instructions, which would force FP state into every trap.
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = std.Target.riscv.featureSet(&.{ .f, .d }),
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("caravan/src/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .medium,
        .red_zone = false,
        .strip = false,
    });
    const options = b.addOptions();
    options.addOption(Board, "board", b.option(Board, "board", "Target board (default qemu_virt)") orelse .qemu_virt);
    kernel_mod.addOptions("build_options", options);

    const kernel = b.addExecutable(.{ .name = "caravan", .root_module = kernel_mod });
    kernel.setLinkerScript(b.path("caravan/src/arch/riscv64/link.ld"));
    kernel.entry = .{ .symbol_name = "_start" };
    b.installArtifact(kernel);

    const qemu_base = [_][]const u8{
        "qemu-system-riscv64", "-machine", "virt",    "-cpu",       "rv64", "-smp", "1", "-m", "256M",
        "-nographic",          "-bios",    "default", "-no-reboot",
    };

    const run = b.addSystemCommand(&qemu_base);
    run.addArg("-kernel");
    run.addArtifactArg(kernel);
    run.stdio = .inherit;
    b.step("run", "Boot Caravan in QEMU").dependOn(&run.step);

    // Deterministic boot through tools/harness.py: -icount ties virtual time
    // to instructions retired, so the same image gives the same trace on every
    // run. The harness prints the kernel's records and fails on a nonzero exit,
    // a timeout, or a missing summary.
    const qtest = b.addSystemCommand(&.{ "python3", "tools/harness.py", "--timeout", qemu_timeout, "--expect", "summary failed=0" });
    qtest.addArtifactArg(kernel);
    qtest.stdio = .inherit;
    qtest.has_side_effects = true;
    b.step("qemu-test", "Boot Caravan in QEMU and run in-kernel self-tests").dependOn(&qtest.step);

    const dbg = b.addSystemCommand(&qemu_base);
    dbg.addArgs(&.{ "-s", "-S", "-kernel" });
    dbg.addArtifactArg(kernel);
    dbg.stdio = .inherit;
    b.step("debug", "Boot halted, waiting for GDB on localhost:1234").dependOn(&dbg.step);

    // The portable core is its own module rooted in caravan/src/core, so the
    // compiler rejects any import of arch/ from it: if it builds for the host,
    // it is hardware-independent and can run under simulation.
    const core_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("caravan/src/core/core.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    const run_core_tests = b.addRunArtifact(core_tests);
    b.step("test", "Run host unit tests for the kernel core").dependOn(&run_core_tests.step);
}
