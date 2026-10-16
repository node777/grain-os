//! Grain OS build graph.
//!
//!   zig build              build the Caravan kernel image (zig-out/bin/caravan)
//!   zig build run          boot it in QEMU (riscv64 virt, serial on stdio)
//!   zig build test         host tests: kernel core, scenarios, simulator
//!   zig build qemu-test    boot in QEMU deterministically (-icount) and check the self-tests
//!   zig build sim          run the deterministic simulator (-Dseed=N -Dsteps=N)
//!   zig build bench        one-hart run printing benchmark records (use -Doptimize=ReleaseFast)
//!   zig build debug        boot halted with a GDB stub on :1234 (see docs/TESTING.md)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const qemu_timeout = b.option([]const u8, "qemu-timeout", "Seconds before a QEMU run is killed") orelse "60";
    const smp = b.option([]const u8, "smp", "Harts for QEMU runs (default 2)") orelse "2";
    const host = b.graph.host;

    // The kernel never touches floating point: drop F/D so the compiler cannot
    // emit FP instructions, which would force FP state into every trap.
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = std.Target.riscv.featureSet(&.{ .f, .d }),
    });
    // User programs get the same baseline for now (no FP context switching yet).
    const user_target = kernel_target;

    // ---- Shared modules ---------------------------------------------------
    // abi: the system-call contract. core: the portable kernel (imports abi
    // only, so it cannot reach hardware code). sv39: the page-table format.
    const abi_mod = b.createModule(.{ .root_source_file = b.path("caravan/abi/abi.zig") });
    const sv39_mod = b.createModule(.{ .root_source_file = b.path("caravan/src/arch/riscv64/sv39.zig") });
    const core_kernel = b.createModule(.{ .root_source_file = b.path("caravan/src/core/core.zig"), .target = kernel_target, .optimize = optimize, .code_model = .medium, .red_zone = false });
    core_kernel.addImport("abi", abi_mod);

    // ---- User programs ----------------------------------------------------
    const klog_mod = b.createModule(.{ .root_source_file = b.path("caravan/src/core/klog.zig") });
    const grain_lib = b.createModule(.{ .root_source_file = b.path("grain/lib/grain.zig") });
    grain_lib.addImport("abi", abi_mod);
    grain_lib.addImport("klog", klog_mod);
    const root_task = b.addExecutable(.{ .name = "root_task", .root_module = b.createModule(.{
        .root_source_file = b.path("grain/root/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .medium,
        .imports = &.{ .{ .name = "grain", .module = grain_lib }, .{ .name = "abi", .module = abi_mod } },
    }) });
    root_task.setLinkerScript(b.path("grain/user.ld"));
    root_task.entry = .{ .symbol_name = "_start" };
    b.installArtifact(root_task);

    // ---- Kernel -----------------------------------------------------------
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("caravan/src/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .medium,
        .red_zone = false,
        .strip = false,
        .imports = &.{
            .{ .name = "core", .module = core_kernel },
            .{ .name = "abi", .module = abi_mod },
            .{ .name = "sv39", .module = sv39_mod },
        },
    });
    kernel_mod.addAnonymousImport("root_task.elf", .{ .root_source_file = root_task.getEmittedBin() });

    const kernel = b.addExecutable(.{ .name = "caravan", .root_module = kernel_mod });
    kernel.setLinkerScript(b.path("caravan/src/arch/riscv64/link.ld"));
    kernel.entry = .{ .symbol_name = "_start" };
    b.installArtifact(kernel);

    const qemu_base = [_][]const u8{
        "qemu-system-riscv64", "-machine", "virt",    "-cpu",       "rv64", "-m", "256M",
        "-nographic",          "-bios",    "default", "-no-reboot",
    };

    const run = b.addSystemCommand(&qemu_base);
    run.addArgs(&.{ "-smp", smp, "-kernel" });
    run.addArtifactArg(kernel);
    run.stdio = .inherit;
    b.step("run", "Boot Caravan in QEMU").dependOn(&run.step);

    // Deterministic boot through tools/harness.py: -icount ties virtual time
    // to instructions retired, so the same image gives the same trace on every
    // run. The harness prints the records and fails on a nonzero exit, a
    // timeout, or a missing summary.
    const qtest = b.addSystemCommand(&.{ "python3", "tools/harness.py", "--timeout", qemu_timeout, "--smp", smp, "--expect", "summary failed=0" });
    qtest.addArtifactArg(kernel);
    qtest.stdio = .inherit;
    qtest.has_side_effects = true;
    b.step("qemu-test", "Boot Caravan in QEMU and run the self-tests").dependOn(&qtest.step);

    // Benchmarks: one hart, so QEMU's global instruction counter (-icount)
    // measures only the code under test. Use -Doptimize=ReleaseFast.
    const bench = b.addSystemCommand(&.{ "python3", "tools/harness.py", "--timeout", qemu_timeout, "--smp", "1", "--expect", "summary failed=0", "--filter", "bench,profile" });
    bench.addArtifactArg(kernel);
    bench.stdio = .inherit;
    bench.has_side_effects = true;
    b.step("bench", "Boot on one hart and print benchmark and profile records").dependOn(&bench.step);

    const dbg = b.addSystemCommand(&qemu_base);
    dbg.addArgs(&.{ "-smp", smp, "-s", "-S", "-kernel" });
    dbg.addArtifactArg(kernel);
    dbg.stdio = .inherit;
    b.step("debug", "Boot halted, waiting for GDB on localhost:1234").dependOn(&dbg.step);

    // ---- Host tests and simulator -------------------------------------------
    const core_host = b.createModule(.{ .root_source_file = b.path("caravan/src/core/core.zig"), .target = host, .optimize = optimize });
    core_host.addImport("abi", abi_mod);
    const test_step = b.step("test", "Run host tests (core, scenarios, simulator)");

    const core_tests = b.addTest(.{ .root_module = core_host });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const sv39_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("caravan/src/arch/riscv64/sv39.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(sv39_tests).step);

    const sim_imports: []const std.Build.Module.Import = &.{
        .{ .name = "core", .module = core_host },
        .{ .name = "abi", .module = abi_mod },
        .{ .name = "sv39", .module = sv39_mod },
    };
    const scenario_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("sim/kernel_test.zig"), .target = host, .optimize = optimize, .imports = sim_imports }) });
    test_step.dependOn(&b.addRunArtifact(scenario_tests).step);

    // The simulator checks every invariant after every step, so it is built
    // with ReleaseSafe: optimised, with all safety checks still on.
    const core_sim = b.createModule(.{ .root_source_file = b.path("caravan/src/core/core.zig"), .target = host, .optimize = .ReleaseSafe });
    core_sim.addImport("abi", abi_mod);
    const sim_exe = b.addExecutable(.{ .name = "caravan-sim", .root_module = b.createModule(.{ .root_source_file = b.path("sim/main.zig"), .target = host, .optimize = .ReleaseSafe, .imports = &.{
        .{ .name = "core", .module = core_sim },
        .{ .name = "abi", .module = abi_mod },
        .{ .name = "sv39", .module = sv39_mod },
    } }) });
    b.installArtifact(sim_exe);
    const sim_run = b.addRunArtifact(sim_exe);
    if (b.option([]const u8, "seed", "Simulator seed (default: a fixed set)")) |seed| sim_run.addArgs(&.{ "--seed", seed });
    if (b.option([]const u8, "steps", "Simulator steps per seed")) |steps| sim_run.addArgs(&.{ "--steps", steps });
    sim_run.has_side_effects = true;
    b.step("sim", "Run the deterministic simulator").dependOn(&sim_run.step);
    // A short simulator run is part of `zig build test`.
    const sim_smoke = b.addRunArtifact(sim_exe);
    sim_smoke.addArgs(&.{ "--seeds", "4", "--steps", "20000" });
    test_step.dependOn(&sim_smoke.step);
}
