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
    const system_path = b.option([]const u8, "system", "System manifest for run/steward/check-manifest: .brix or .zon (default system/dev.brix)") orelse "system/dev.brix";
    const program_names = [_][]const u8{ "virtio_console", "virtio_rng", "hello", "flaky", "checker", "crasher", "waiter", "registry", "kv", "envoy", "tablecloth", "kumara", "ledger", "surf", "shell", "mycelium", "comlink", "guestbook" };

    const pack = b.addExecutable(.{ .name = "grain-pack", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/pack/main.zig"),
        .target = host,
        .optimize = .Debug,
        .imports = &.{ .{ .name = "schema", .module = schema_mod }, .{ .name = "image", .module = image_mod } },
    }) });
    // Brix, the manifest language: `brix` evaluates a .brix file, runs the
    // full manifest check, and writes the plain data (ZON) everything else
    // reads. A .zon manifest is used as it is.
    const brix_mod = b.createModule(.{ .root_source_file = b.path("grain/brix/brix.zig") });
    const brix_exe = b.addExecutable(.{ .name = "brix", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/brix/main.zig"),
        .target = host,
        .optimize = .Debug,
        .imports = &.{ .{ .name = "brix", .module = brix_mod }, .{ .name = "schema", .module = schema_mod }, .{ .name = "proto", .module = proto_mod } },
    }) });
    b.installArtifact(brix_exe);

    // grain-disk: Tablecloth disks on the host. Tests boot from a fresh copy
    // of a cheap one (Argon2id at 1 MiB, one pass: test-only).
    const tablecloth_mod = b.createModule(.{ .root_source_file = b.path("grain/lib/tablecloth.zig") });
    const disk_exe = b.addExecutable(.{ .name = "grain-disk", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/disk/main.zig"),
        .target = host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "tablecloth", .module = tablecloth_mod }},
    }) });
    b.installArtifact(disk_exe);
    const test_disk_run = b.addRunArtifact(disk_exe);
    test_disk_run.addArg("format");
    const test_disk = test_disk_run.addOutputFileArg("disk.img");
    b.getInstallStep().dependOn(&b.addInstallFile(test_disk, "test-disk.img").step);
    test_disk_run.addArgs(&.{ "64", "--kdf-kib", "1024", "--kdf-t", "1" });
    const Manifest = struct {
        fn zon(bb: *std.Build, tool: *std.Build.Step.Compile, path: []const u8) std.Build.LazyPath {
            if (!std.mem.endsWith(u8, path, ".brix")) return bb.path(path);
            const run = bb.addRunArtifact(tool);
            run.addFileArg(bb.path(path));
            return run.addOutputFileArg(bb.fmt("{s}.zon", .{std.fs.path.stem(path)}));
        }
    };
    const system_zon = Manifest.zon(b, brix_exe, system_path);

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
        fn steward(bb: *std.Build, label: []const u8, tag: []const u8, manifest: std.Build.LazyPath, packer: *std.Build.Step.Compile, progs: []const *std.Build.Step.Compile, names: []const []const u8, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
            const pack_run = bb.addRunArtifact(packer);
            const img = pack_run.addOutputFileArg("system.img");
            pack_run.addFileArg(manifest);
            // grain-pack keeps only what Steward loads of each program (the
            // installed zig-out/bin/programs/* keep their symbols for gdb).
            for (progs, names) |p, name| pack_run.addPrefixedFileArg(bb.fmt("{s}=", .{name}), p.getEmittedBin());
            const s = UserProgram.add(bb, bb.fmt("steward-{s}", .{label}), "grain/steward/main.zig", target, opt, imports);
            s.root_module.addAnonymousImport("system.zon", .{ .root_source_file = manifest });
            s.root_module.addAnonymousImport("system.img", .{ .root_source_file = img });
            const opts = bb.addOptions();
            opts.addOption([]const u8, "tag", tag);
            s.root_module.addOptions("build_tag", opts);
            bb.getInstallStep().dependOn(&bb.addInstallFile(img, bb.fmt("{s}.img", .{label})).step);
            return s;
        }
    };
    const steward = System.steward(b, "system", "main", system_zon, pack, &programs, &program_names, user_target, optimize, steward_imports);
    const steward_faults = System.steward(b, "faults", "main", Manifest.zon(b, brix_exe, "system/tests/faults.brix"), pack, &programs, &program_names, user_target, optimize, steward_imports);
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
    check.root_module.addAnonymousImport("system.zon", .{ .root_source_file = system_zon });
    b.step("check-manifest", "Check the system manifest at compile time").dependOn(&check.step);

    const ktest_root = UserProgram.add(b, "ktest", "grain/ktest/main.zig", user_target, optimize, user_imports);
    b.installArtifact(ktest_root);

    // ---- Kernels ----------------------------------------------------------
    // caravan:       the kernel with Steward as root task (the real system)
    // caravan-ktest: the kernel with the kernel test suite as root task
    const Kernel = struct {
        fn add(bb: *std.Build, name: []const u8, root: *std.Build.Step.Compile, packer: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
            const mod = bb.createModule(.{
                .root_source_file = bb.path("caravan/src/main.zig"),
                .target = target,
                .optimize = opt,
                .code_model = .medium,
                .red_zone = false,
                .strip = false,
                .imports = imports,
            });
            // The root task goes in compacted (loadable bytes only); gdb
            // uses the installed copy.
            const compact = bb.addRunArtifact(packer);
            compact.addArg("compact");
            compact.addFileArg(root.getEmittedBin());
            mod.addAnonymousImport("root_task.elf", .{ .root_source_file = compact.addOutputFileArg("root_task.elf") });
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
    const kernel = Kernel.add(b, "caravan", steward, pack, kernel_target, optimize, kernel_imports);
    // Aurora: the boot stage that picks a generation from the disk and loads
    // it. Boot it as QEMU's -kernel, with a disk that holds generations.
    const aurora = b.addExecutable(.{ .name = "aurora", .root_module = b.createModule(.{
        .root_source_file = b.path("aurora/main.zig"),
        .target = kernel_target,
        .optimize = .ReleaseSafe,
        .code_model = .medium,
        .imports = &.{
            .{ .name = "grain", .module = grain_lib },
            .{ .name = "klog", .module = klog_mod },
            .{ .name = "fdt", .module = b.createModule(.{ .root_source_file = b.path("caravan/src/core/fdt.zig") }) },
            .{ .name = "sbi", .module = b.createModule(.{ .root_source_file = b.path("caravan/src/arch/riscv64/sbi.zig") }) },
        },
    }) });
    aurora.setLinkerScript(b.path("aurora/link.ld"));
    aurora.entry = .{ .symbol_name = "_start" };
    b.installArtifact(aurora);
    const ktest = Kernel.add(b, "caravan-ktest", ktest_root, pack, kernel_target, optimize, kernel_imports);
    // The same system, tagged "next": the generation tests upgrade to it.
    const steward_next = System.steward(b, "next", "next", system_zon, pack, &programs, &program_names, user_target, optimize, steward_imports);
    const kernel_next = Kernel.add(b, "caravan-next", steward_next, pack, kernel_target, optimize, kernel_imports);
    const kernel_faults = Kernel.add(b, "caravan-faults", steward_faults, pack, kernel_target, optimize, kernel_imports);

    // Devices for the system image. virtio-rng reads a fixed pattern file, so
    // runs stay deterministic; the virtio console writes to a file the
    // harness checks.
    const rng_bytes = b.allocator.alloc(u8, 65536) catch @panic("oom");
    for (rng_bytes, 0..) |*c, i| c.* = @truncate((i *% 2654435761) >> 7);
    const rng_file = b.addWriteFiles().add("rng.bin", rng_bytes);
    // A second pattern, for a second instance with another identity.
    const rng_b_bytes = b.allocator.alloc(u8, 65536) catch @panic("oom");
    for (rng_b_bytes, 0..) |*c, i| c.* = @truncate((i *% 2246822519 +% 12345) >> 9);
    const rng_file_b = b.addWriteFiles().add("rng-b.bin", rng_b_bytes);

    const qemu_base = [_][]const u8{
        "qemu-system-riscv64", "-machine", "virt",    "-cpu",       "rv64", "-m", "256M",
        "-nographic",          "-bios",    "default", "-no-reboot",
    };

    // Interactive: real time, and an Envoy socket to connect an agent or
    // grainsh to (the harness prints the command). `bye` ends the run.
    // The system boots the way a device does: Aurora loads it from the disk.
    // Each build is added to a disk that persists between runs (the
    // passphrase, identity and Ledger live there), zig-out/run-disk.img, and
    // made current; the build before stays the rollback target. Delete the
    // disk to start over.
    const run_disk = b.addRunArtifact(disk_exe);
    run_disk.addArgs(&.{ "dev", "zig-out/run-disk.img", "256" });
    run_disk.addArtifactArg(kernel);
    run_disk.addArg("grain-dev");
    run_disk.has_side_effects = true;
    const run = b.addSystemCommand(&.{ "python3", "tools/harness.py", "--interactive", "--smp", smp, "--virtio-console", "--disk-inplace", "--disk=zig-out/run-disk.img" });
    run.step.dependOn(&run_disk.step);
    // Real entropy: a new disk gets its own master key and identity (tests
    // use a fixed pattern so their names are known).
    run.addArg("--virtio-rng=/dev/urandom");
    // -Ddisplay: the desktop, in a window on the host.
    if (b.option(bool, "display", "zig build run: show the desktop in a window") orelse false) run.addArgs(&.{ "--display", "--window" });
    run.addArtifactArg(aurora);
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

    // Storage: the dev system with a disk, booted twice. The first boot finds
    // a blank store and takes a new passphrase; the second refuses a wrong
    // one and unlocks with the right one.
    const qtest_storage = b.addSystemCommand(&.{
        "python3",                                          "tools/harness.py",
        "--timeout",                                        qemu_timeout,
        "--smp",                                            smp,
        "--virtio-console",                                 "--boots",
        "2",                                                "--console-input",
        "1:open sesame",                                    "--console-input",
        "1:open sesame",                                    "--console-input",
        "2:wrong guess",                                    "--console-input",
        "2:open sesame",                                    "--expect",
        "1:tablecloth_unlocked created=true",               "--expect",
        "2:tablecloth_unlock_failed tries=1",               "--expect",
        "2:tablecloth_unlocked created=false tries=2",      "--expect",
        "domain_ready domain=tablecloth boot_healthy=true", "--expect",
        "summary failed=0",                                 "--expect-console",
        "1:Choose a passphrase",
        // The identity is made once and survives the reboot (the test
        // entropy is a fixed pattern, so its name is known).
                                   "--expect",
        "1:kumara_ready name=sift-noon-city created=true",  "--expect",
        "2:kumara_ready name=sift-noon-city created=false",
    });
    qtest_storage.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_storage.addPrefixedFileArg("--disk=", test_disk);
    qtest_storage.addArtifactArg(kernel);
    qtest_storage.stdio = .inherit;
    qtest_storage.has_side_effects = true;
    qtest_storage.step.dependOn(&qtest_system.step);

    // The same, on an NVMe drive: Steward finds it on the PCI bus, places
    // its BAR and routes its interrupt; Tablecloth drives it natively.
    const qtest_nvme = b.addSystemCommand(&.{
        "python3",                                          "tools/harness.py",
        "--timeout",                                        qemu_timeout,
        "--smp",                                            smp,
        "--virtio-console",                                 "--boots",
        "2",                                                "--disk-bus",
        "nvme",                                             "--console-input",
        "1:open sesame",                                    "--console-input",
        "1:open sesame",                                    "--console-input",
        "2:open sesame",                                    "--expect",
        "device_found bus=pci class=0x10802",               "--expect",
        "disk_ready domain=tablecloth bus=pci",             "--expect",
        "1:kumara_ready name=sift-noon-city created=true",  "--expect",
        "2:kumara_ready name=sift-noon-city created=false",
    });
    qtest_nvme.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_nvme.addPrefixedFileArg("--disk=", test_disk);
    qtest_nvme.addArtifactArg(kernel);
    qtest_nvme.stdio = .inherit;
    qtest_nvme.has_side_effects = true;
    qtest_nvme.step.dependOn(&qtest_storage.step);

    // The same system with a disk and an agent attached to Envoy:
    // tools/agent_session.py exercises every verb, the leases' limits, the
    // audit chain, the identity, and that every action reached the Ledger. Real time
    // (leases expire by the clock), so this run is not deterministic.
    const qtest_agent = b.addSystemCommand(&.{
        "python3",          "tools/harness.py",
        "--timeout",        qemu_timeout,
        "--smp",            smp,
        "--virtio-console", "--realtime",
        "--agent",          "tools/agent_session.py",
        "--console-input",  "open sesame",
        "--console-input",  "open sesame",
        "--expect",         "kumara_ready domain=kumara created=true",
        "--expect",         "ledger_ready domain=ledger entries=0",
        "--expect",         "envoy_ready domain=envoy capabilities=7",
        "--expect",         "envoy_bye domain=envoy",
        "--expect",         "domain_exit domain=envoy code=0",
        "--expect",         "summary failed=0",
        "--expect-console", "agent was here",
    });
    qtest_agent.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_agent.addPrefixedFileArg("--disk=", test_disk);
    qtest_agent.addArtifactArg(kernel);
    qtest_agent.stdio = .inherit;
    qtest_agent.has_side_effects = true;
    qtest_agent.step.dependOn(&qtest_nvme.step);

    // The desktop: a screen, keyboard and tablet driven through QEMU's
    // monitor. tools/desktop_session.py opens the shell from the dock, types
    // a command, clicks a button, and holds the scene an agent reads through
    // Envoy (scene.v1) against screenshots, element by element.
    const qtest_desktop = b.addSystemCommand(&.{
        "python3",          "tools/harness.py",
        "--timeout",        qemu_timeout,
        "--smp",            smp,
        "--virtio-console", "--display",
        "--agent",          "tools/desktop_session.py",
        "--console-input",  "open sesame",
        "--console-input",  "open sesame",
        "--expect",         "surf_ready domain=surf width=1024 height=768 screen=virtio keyboard=true pointer=true",
        "--expect",         "surf_window_shown domain=surf owner=shell",
        "--expect",         "shell_ran domain=shell command=whoami ok=true",
        "--expect",         "surf_window_hidden domain=surf owner=shell",
        "--expect",         "envoy_bye domain=envoy",
    });
    qtest_desktop.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_desktop.addPrefixedFileArg("--disk=", test_disk);
    qtest_desktop.addArtifactArg(kernel);
    qtest_desktop.stdio = .inherit;
    qtest_desktop.has_side_effects = true;
    qtest_desktop.step.dependOn(&qtest_agent.step);

    // The same session on the hardware a PC has: a plain linear framebuffer
    // (bochs-display, PCI) and a USB keyboard and tablet behind an xHCI
    // controller. Same scene, same checks; only the drivers differ.
    const qtest_native = b.addSystemCommand(&.{
        "python3",          "tools/harness.py",
        "--timeout",        qemu_timeout,
        "--smp",            smp,
        "--virtio-console", "--display=native",
        "--agent",          "tools/desktop_session.py",
        "--console-input",  "open sesame",
        "--console-input",  "open sesame",
        "--expect",         "surf_usb domain=surf devices=2",
        "--expect",         "surf_ready domain=surf width=1024 height=768 screen=bochs usb=true",
        "--expect",         "shell_ran domain=shell command=whoami ok=true",
        "--expect",         "surf_window_hidden domain=surf owner=shell",
        "--expect",         "envoy_bye domain=envoy",
    });
    qtest_native.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_native.addPrefixedFileArg("--disk=", test_disk);
    qtest_native.addArtifactArg(kernel);
    qtest_native.stdio = .inherit;
    qtest_native.has_side_effects = true;
    qtest_native.step.dependOn(&qtest_desktop.step);

    // Two instances on one link (tools/pair.py): they introduce themselves,
    // one lends the other its guestbook on a lease, a file moves by its
    // hash, and access is revoked (tools/comlink_session.py). A has a
    // virtio network device, B an Intel e1000 on PCI. Real time:
    // two virtual clocks under -icount would not agree on a timeout.
    const qtest_pair = b.addSystemCommand(&.{ "python3", "tools/pair.py", "--realtime", "--nic-b", "e1000", "--timeout", "240", "--smp", smp, "--scenario", "tools/comlink_session.py" });
    qtest_pair.addPrefixedFileArg("--rng-a=", rng_file);
    qtest_pair.addPrefixedFileArg("--rng-b=", rng_file_b);
    qtest_pair.addPrefixedFileArg("--disk-a=", test_disk);
    qtest_pair.addPrefixedFileArg("--disk-b=", test_disk);
    qtest_pair.addArtifactArg(kernel);
    qtest_pair.stdio = .inherit;
    qtest_pair.has_side_effects = true;
    qtest_pair.step.dependOn(&qtest_native.step);

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
    qtest_faults.step.dependOn(&qtest_pair.step);

    // A miswired manifest must fail to compile, with the explanation.
    const miswired = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "check-manifest", "-Dsystem=system/tests/miswired.brix" });
    miswired.expectExitCode(1);
    miswired.expectStdErrMatch("domain 'hello' uses 'console.consol', but no domain provides it");
    miswired.has_side_effects = true;

    // Generations, booted through Aurora. Upgrade: an agent uploads the
    // "next" build (only the chunks the disk lacks) and switches; the power
    // is cut right after Aurora records the trial boot, which then succeeds
    // and is confirmed; the agent rolls back; the power is cut mid-confirm;
    // the rollback completes; the agent forgets the old generation and
    // reclaims its space, and the system still boots. The identity is the
    // same throughout.
    const gen_disk_run = b.addRunArtifact(disk_exe);
    gen_disk_run.addArg("format");
    const gen_disk = gen_disk_run.addOutputFileArg("gen-disk.img");
    gen_disk_run.addArgs(&.{ "64", "--kdf-kib", "1024", "--kdf-t", "1", "--install" });
    gen_disk_run.addArtifactArg(kernel);
    gen_disk_run.addArg("grain-dev");
    const next_pack_run = b.addRunArtifact(disk_exe);
    next_pack_run.addArg("pack");
    next_pack_run.addArtifactArg(kernel_next);
    next_pack_run.addArg("grain-dev");
    const next_pack = next_pack_run.addOutputDirectoryArg("next");
    const qtest_gen = b.addSystemCommand(&.{
        "python3",                                          "tools/harness.py",
        "--timeout",                                        "330",
        "--smp",                                            smp,
        "--virtio-console",                                 "--boots",
        "8",                                                "--console-input",
        "open sesame",                                      "--console-input",
        "open sesame",                                      "--agent",
        "1:tools/gen_upgrade.py",                           "--agent",
        "4:tools/gen_rollback.py",                          "--agent",
        "7:tools/gen_forget.py",                            "--kill-on",
        "2:boot trial=true tries=1",                        "--kill-on",
        "5:domain_ready domain=tablecloth",                 "--expect",
        "1:boot trial=false",                               "--expect",
        "1:steward_start tag=main",                         "--expect",
        "1:generation_staged by=agent",                     "--expect",
        "1:kumara_ready name=sift-noon-city created=true",  "--expect",
        "2:boot trial=true tries=1",                        "--expect",
        "3:boot trial=true tries=2",                        "--expect",
        "3:steward_start tag=next",                         "--expect",
        "3:generation_confirmed promoted=true",             "--expect",
        "3:kumara_ready name=sift-noon-city created=false", "--expect",
        "4:steward_start tag=next",                         "--expect",
        "4:generation_staged by=agent rollback=true",       "--expect",
        "5:boot trial=true tries=1",                        "--expect",
        "6:boot trial=true tries=2",                        "--expect",
        "6:steward_start tag=main",                         "--expect",
        "6:generation_confirmed promoted=true",             "--expect",
        "6:kumara_ready name=sift-noon-city created=false", "--expect",
        "7:generation_forgotten by=agent",                  "--expect",
        "7:tablecloth_reclaimed",                           "--expect",
        "8:boot trial=false",                               "--expect",
        "8:steward_start tag=main",                         "--expect",
        "8:kumara_ready name=sift-noon-city created=false",
    });
    qtest_gen.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_gen.addPrefixedFileArg("--disk=", gen_disk);
    qtest_gen.addPrefixedDirectoryArg("--agent-env=GRAIN_NEXT=", next_pack);
    qtest_gen.addArtifactArg(aurora);
    qtest_gen.stdio = .inherit;
    qtest_gen.has_side_effects = true;
    qtest_gen.step.dependOn(&qtest_faults.step);

    // A generation that never comes up (the faults system has no store, so it
    // never confirms) is tried three times; then Aurora boots the last good one.
    const broken_disk_run = b.addRunArtifact(disk_exe);
    broken_disk_run.addArg("format");
    const broken_disk = broken_disk_run.addOutputFileArg("broken-disk.img");
    broken_disk_run.addArgs(&.{ "64", "--kdf-kib", "1024", "--kdf-t", "1", "--install" });
    broken_disk_run.addArtifactArg(kernel);
    broken_disk_run.addArgs(&.{ "grain-dev", "--stage" });
    broken_disk_run.addArtifactArg(kernel_faults);
    broken_disk_run.addArg("grain-faults");
    const qtest_giveup = b.addSystemCommand(&.{
        "python3",                                      "tools/harness.py",
        "--timeout",                                    "240",
        "--smp",                                        smp,
        "--virtio-console",                             "--boots",
        "4",                                            "--console-input",
        "4:open sesame",                                "--console-input",
        "4:open sesame",                                "--expect",
        "1:boot trial=true tries=1 label=grain-faults", "--expect",
        "2:boot trial=true tries=2 label=grain-faults", "--expect",
        "3:boot trial=true tries=3 label=grain-faults", "--expect",
        "3:steward_start system=grain-faults",          "--expect",
        "4:gave_up",                                    "--expect",
        "4:boot trial=false label=grain-dev",           "--expect",
        "4:steward_start system=grain-dev",             "--expect",
        "4:summary failed=0",
    });
    qtest_giveup.addPrefixedFileArg("--virtio-rng=", rng_file);
    qtest_giveup.addPrefixedFileArg("--disk=", broken_disk);
    qtest_giveup.addArtifactArg(aurora);
    qtest_giveup.stdio = .inherit;
    qtest_giveup.has_side_effects = true;
    qtest_giveup.step.dependOn(&qtest_gen.step);

    const qtest = b.step("qemu-test", "Boot the kernel test suite and the system in QEMU");
    qtest.dependOn(&qtest_giveup.step);
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
    const manifest_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/manifest/manifest_test.zig"), .target = host, .optimize = optimize, .imports = &.{ .{ .name = "schema", .module = schema_mod }, .{ .name = "brix", .module = brix_mod } } }) });
    inline for (.{ "dev", "tests/faults", "tests/miswired" }) |name| {
        manifest_tests.root_module.addAnonymousImport(comptime std.fs.path.basename(name) ++ ".brix", .{ .root_source_file = b.path("system/" ++ name ++ ".brix") });
    }
    test_step.dependOn(&b.addRunArtifact(manifest_tests).step);
    // Tablecloth, including the crash simulator (a power cut at every device
    // operation of a generation upgrade and rollback).
    const generation_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/lib/generation.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(generation_tests).step);
    const kumara_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/lib/kumara.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(kumara_tests).step);
    const tablecloth_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/lib/tablecloth.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(tablecloth_tests).step);
    const paint_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/lib/paint.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(paint_tests).step);
    const input_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/lib/virtio_input.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(input_tests).step);
    for ([_][]const u8{ "grain/lib/net.zig", "grain/lib/noise.zig", "grain/lib/pci.zig", "grain/lib/xhci.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = host, .optimize = optimize }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    const brix_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("grain/brix/brix.zig"), .target = host, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(brix_tests).step);
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
