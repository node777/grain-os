//! Grain OS build graph.
//!
//!   zig build              build everything: zig-out/bin/caravan (the system: kernel +
//!                          Steward + the manifest's programs), caravan-ktest (kernel tests)
//!   zig build run          boot the system in QEMU in real time with an Envoy socket
//!                          (connect: python3 tools/envoy.py shell --socket PATH)
//!   zig build test         host tests: kernel core, scenarios, manifest, image, simulator
//!   zig build qemu-test    boot the images in QEMU and check them: kernel tests,
//!                          system and faults deterministically, an agent session in real time
//!   zig build check-manifest -Dsystem=path   check a manifest at compile time
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
    const schema_mod = b.createModule(.{ .root_source_file = b.path("grain/manifest/schema.zig") });
    const image_mod = b.createModule(.{ .root_source_file = b.path("grain/manifest/image.zig") });
    // Portable parts of the kernel core that user programs reuse as libraries.
    const elf_mod = b.createModule(.{ .root_source_file = b.path("caravan/src/core/elf.zig") });
    const fdt_mod = b.createModule(.{ .root_source_file = b.path("caravan/src/core/fdt.zig") });

    const UserProgram = struct {
        fn add(bb: *std.Build, name: []const u8, root: []const u8, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
            const exe = bb.addExecutable(.{ .name = name, .root_module = bb.createModule(.{
                .root_source_file = bb.path(root),
                .target = target,
                .optimize = opt,
                .code_model = .medium,
                .imports = imports,
            }) });
            exe.setLinkerScript(bb.path("grain/user.ld"));
            exe.entry = .{ .symbol_name = "_start" };
            return exe;
        }
    };
    const proto_mod = b.createModule(.{ .root_source_file = b.path("grain/proto/proto.zig"), .imports = &.{.{ .name = "grain", .module = grain_lib }} });
    const user_imports: []const std.Build.Module.Import = &.{ .{ .name = "grain", .module = grain_lib }, .{ .name = "abi", .module = abi_mod }, .{ .name = "proto", .module = proto_mod } };

    // Systems: each is a manifest plus the programs it names, packed into a
    // boot image and embedded in its own Steward. grain-pack refuses an image
    // missing a program, and Steward refuses a miswired manifest at compile time.
    const system_path = b.option([]const u8, "system", "System manifest for run/steward/check-manifest (default system/dev.zon)") orelse "system/dev.zon";
    const program_names = [_][]const u8{ "virtio_console", "virtio_rng", "hello", "flaky", "checker", "crasher", "waiter", "registry", "kv", "envoy" };

    const pack = b.addExecutable(.{ .name = "grain-pack", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/pack/main.zig"),
        .target = host,
        .optimize = .Debug,
        .imports = &.{ .{ .name = "schema", .module = schema_mod }, .{ .name = "image", .module = image_mod } },
    }) });
    var programs: [program_names.len]*std.Build.Step.Compile = undefined;
    for (program_names, 0..) |name, i| {
        programs[i] = UserProgram.add(b, name, b.fmt("grain/programs/{s}/main.zig", .{name}), user_target, optimize, user_imports);
        b.getInstallStep().dependOn(&b.addInstallArtifact(programs[i], .{ .dest_sub_path = b.fmt("programs/{s}", .{name}) }).step);
    }
    const steward_imports: []const std.Build.Module.Import = &.{
        .{ .name = "grain", .module = grain_lib },
        .{ .name = "abi", .module = abi_mod },
        .{ .name = "schema", .module = schema_mod },
        .{ .name = "image", .module = image_mod },
        .{ .name = "elf", .module = elf_mod },
        .{ .name = "fdt", .module = fdt_mod },
        .{ .name = "proto", .module = proto_mod },
    };
    const System = struct {
        fn steward(bb: *std.Build, label: []const u8, manifest: []const u8, packer: *std.Build.Step.Compile, progs: []const *std.Build.Step.Compile, names: []const []const u8, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
            const pack_run = bb.addRunArtifact(packer);
            const img = pack_run.addOutputFileArg("system.img");
            pack_run.addFileArg(bb.path(manifest));
            for (progs, names) |p, name| pack_run.addPrefixedFileArg(bb.fmt("{s}=", .{name}), p.getEmittedBin());
            const s = UserProgram.add(bb, bb.fmt("steward-{s}", .{label}), "grain/steward/main.zig", target, opt, imports);
            s.root_module.addAnonymousImport("system.zon", .{ .root_source_file = bb.path(manifest) });
            s.root_module.addAnonymousImport("system.img", .{ .root_source_file = img });
            bb.getInstallStep().dependOn(&bb.addInstallFile(img, bb.fmt("{s}.img", .{label})).step);
            return s;
        }
    };
    const steward = System.steward(b, "system", system_path, pack, &programs, &program_names, user_target, optimize, steward_imports);
    const steward_faults = System.steward(b, "faults", "system/tests/faults.zon", pack, &programs, &program_names, user_target, optimize, steward_imports);
    b.installArtifact(steward);
    b.step("steward", "Build Steward for the system manifest (-Dsystem=...)").dependOn(&b.addInstallArtifact(steward, .{}).step);

    // `zig build check-manifest -Dsystem=...` compiles the manifest check
    // alone: a miswired manifest is a compile error.
    const check = b.addObject(.{ .name = "manifest-check", .root_module = b.createModule(.{
        .root_source_file = b.path("grain/manifest/check.zig"),
        .target = host,
        .optimize = .Debug,
        .imports = &.{ .{ .name = "schema", .module = schema_mod }, .{ .name = "proto", .module = proto_mod } },
    }) });
    check.root_module.addAnonymousImport("system.zon", .{ .root_source_file = b.path(system_path) });
    b.step("check-manifest", "Check the system manifest at compile time").dependOn(&check.step);

    const ktest_root = UserProgram.add(b, "ktest", "grain/ktest/main.zig", user_target, optimize, user_imports);
    b.installArtifact(ktest_root);

    // ---- Kernels ----------------------------------------------------------
    // caravan:       the kernel with Steward as root task (the real system)
    // caravan-ktest: the kernel with the kernel test suite as root task
    const Kernel = struct {
        fn add(bb: *std.Build, name: []const u8, root: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
            const mod = bb.createModule(.{
                .root_source_file = bb.path("caravan/src/main.zig"),
                .target = target,
                .optimize = opt,
                .code_model = .medium,
                .red_zone = false,
                .strip = false,
                .imports = imports,
            });
            mod.addAnonymousImport("root_task.elf", .{ .root_source_file = root.getEmittedBin() });
            const k = bb.addExecutable(.{ .name = name, .root_module = mod });
            k.setLinkerScript(bb.path("caravan/src/arch/riscv64/link.ld"));
            k.entry = .{ .symbol_name = "_start" };
            bb.installArtifact(k);
            return k;
        }
    };
    const kernel_imports: []const std.Build.Module.Import = &.{
        .{ .name = "core", .module = core_kernel },
        .{ .name = "abi", .module = abi_mod },
        .{ .name = "sv39", .module = sv39_mod },
    };
    const kernel = Kernel.add(b, "caravan", steward, kernel_target, optimize, kernel_imports);
    const ktest = Kernel.add(b, "caravan-ktest", ktest_root, kernel_target, optimize, kernel_imports);
    const kernel_faults = Kernel.add(b, "caravan-faults", steward_faults, kernel_target, optimize, kernel_imports);

    // Devices for the system image. virtio-rng reads a fixed pattern file, so
    // runs stay deterministic; the virtio console writes to a file the
    // harness checks.
    const rng_bytes = b.allocator.alloc(u8, 65536) catch @panic("oom");
    for (rng_bytes, 0..) |*c, i| c.* = @truncate((i *% 2654435761) >> 7);
    const rng_file = b.addWriteFiles().add("rng.bin", rng_bytes);

    const qemu_base = [_][]const u8{
        "qemu-system-riscv64", "-machine", "virt",    "-cpu",       "rv64", "-m", "256M",
        "-nographic",          "-bios",    "default", "-no-reboot",
    };

    // Interactive: real time, and an Envoy socket to connect an agent or
    // grainsh to (the harness prints the command). `bye` ends the run.
    const run = b.addSystemCommand(&.{ "python3", "tools/harness.py", "--interactive", "--smp", smp, "--virtio-console" });
    run.addPrefixedFileArg("--virtio-rng=", rng_file);
    run.addArtifactArg(kernel);
    run.stdio = .inherit;
    run.has_side_effects = true;
    b.step("run", "Boot the system in QEMU and show its output").dependOn(&run.step);

    // Deterministic boots through tools/harness.py: -icount ties virtual time
    // to instructions retired, so the same image gives the same trace on every
    // run. The harness prints the records and fails on a nonzero exit, a
    // timeout, a missing expected record or missing console text.
    const qtest_kernel = b.addSystemCommand(&.{ "python3", "tools/harness.py", "--timeout", qemu_timeout, "--smp", smp, "--expect", "summary failed=0", "--expect", "long_write_ok text=01234567890123456789012345678901234567890123456789012345678901234567890123456789" });
    qtest_kernel.addArtifactArg(ktest);
    qtest_kernel.stdio = .inherit;
    qtest_kernel.has_side_effects = true;

    const qtest_system = b.addSystemCommand(&.{
        "python3",                                           "tools/harness.py",
        "--timeout",                                         qemu_timeout,
        "--smp",                                             smp,
        "--virtio-console",                                  "--expect",
        "steward_start verified=true",                       "--expect",
        "driver_ready domain=console",                       "--expect",
        "driver_ready domain=rng",                           "--expect",
        "domain_fault domain=flaky",                         "--expect",
        "domain_start domain=flaky restart=1",               "--expect",
        "echo_ok domain=checker answer=42",                  "--expect",
        "domain_exit domain=hello code=0",                   "--expect",
        "summary failed=0",                                  "--expect-console",
        "hello from grain! entropy 00f3e6dacdc0b4a7",        "--expect-console",
        "checker: flaky.echo answered 42",                   "--expect",
        "domain_skipped domain=envoy reason=device_missing",
    });
    qtest_system.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_system.addArtifactArg(kernel);
    qtest_system.stdio = .inherit;
    qtest_system.has_side_effects = true;
    qtest_system.step.dependOn(&qtest_kernel.step);

    // The same system with an agent attached to Envoy: tools/agent_session.py
    // exercises every verb, the leases' limits and the audit chain. Real time
    // (leases expire by the clock), so this run is not deterministic.
    const qtest_agent = b.addSystemCommand(&.{
        "python3",          "tools/harness.py",
        "--timeout",        qemu_timeout,
        "--smp",            smp,
        "--virtio-console", "--realtime",
        "--agent",          "tools/agent_session.py",
        "--expect",         "envoy_ready domain=envoy capabilities=4",
        "--expect",         "envoy_bye domain=envoy",
        "--expect",         "domain_exit domain=envoy code=0",
        "--expect",         "summary failed=0",
        "--expect-console", "agent was here",
    });
    qtest_agent.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_agent.addArtifactArg(kernel);
    qtest_agent.stdio = .inherit;
    qtest_agent.has_side_effects = true;
    qtest_agent.step.dependOn(&qtest_system.step);

    // The failure path: restart limit, service revocation, no hung client.
    const qtest_faults = b.addSystemCommand(&.{
        "python3",   "tools/harness.py",
        "--timeout", qemu_timeout,
        "--smp",     smp,
        "--expect",  "domain_start domain=crasher restart=2",
        "--expect",  "domain_stopped domain=crasher reason=restart_limit",
        "--expect",  "service_revoked domain=crasher service=echo",
        "--expect",  "call_again domain=waiter status=invalid_cap",
        "--expect",  "domain_exit domain=waiter code=0",
        "--expect",  "summary failed=0",
    });
    qtest_faults.addArtifactArg(kernel_faults);
    qtest_faults.stdio = .inherit;
    qtest_faults.has_side_effects = true;
    qtest_faults.step.dependOn(&qtest_agent.step);

    // A miswired manifest must fail to compile, with the explanation.
    const miswired = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "check-manifest", "-Dsystem=system/tests/miswired.zon" });
    miswired.expectExitCode(1);
    miswired.expectStdErrMatch("domain 'hello' uses 'console.consol', but no domain provides it");
    miswired.has_side_effects = true;

    const qtest = b.step("qemu-test", "Boot the kernel test suite and the system in QEMU");
    qtest.dependOn(&qtest_faults.step);
    qtest.dependOn(&miswired.step);

    // Benchmarks: one hart, so QEMU's global instruction counter (-icount)
    // measures only the code under test. Use -Doptimize=ReleaseFast.
    const bench = b.addSystemCommand(&.{ "python3", "tools/harness.py", "--timeout", qemu_timeout, "--smp", "1", "--expect", "summary failed=0", "--filter", "bench,profile" });
    bench.addArtifactArg(ktest);
    bench.stdio = .inherit;
    bench.has_side_effects = true;
    b.step("bench", "Boot the kernel test suite on one hart and print benchmark and profile records").dependOn(&bench.step);

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

    const schema_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/manifest/schema.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(schema_tests).step);
    const manifest_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/manifest/manifest_test.zig"), .target = host, .optimize = optimize, .imports = &.{.{ .name = "schema", .module = schema_mod }} }) });
    manifest_tests.root_module.addAnonymousImport("dev.zon", .{ .root_source_file = b.path("system/dev.zon") });
    manifest_tests.root_module.addAnonymousImport("miswired.zon", .{ .root_source_file = b.path("system/tests/miswired.zon") });
    manifest_tests.root_module.addAnonymousImport("faults.zon", .{ .root_source_file = b.path("system/tests/faults.zon") });
    test_step.dependOn(&b.addRunArtifact(manifest_tests).step);
    const idl_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/lib/idl.zig"), .target = host, .optimize = optimize, .imports = &.{ .{ .name = "abi", .module = abi_mod }, .{ .name = "klog", .module = klog_mod } } }) });
    test_step.dependOn(&b.addRunArtifact(idl_tests).step);
    const image_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/manifest/image.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(image_tests).step);

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
