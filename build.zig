const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Log.zig dependency
    const logz = b.dependency("logz", .{
        .target = target,
        .optimize = optimize,
    }).module("logz");

    // Toml dependency
    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    }).module("toml");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // add tree-sitter as dependency
    const tree_sitter = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });

    exe_module.addImport("logz", logz);
    exe_module.addImport("toml", toml);
    exe_module.addImport("tree-sitter", tree_sitter.module("tree_sitter"));

    addTreeSitterGrammar(b, exe_module, "tree-sitter-zig");
    addTreeSitterGrammar(b, exe_module, "tree-sitter-go");
    addTreeSitterGrammar(b, exe_module, "tree-sitter-toml");
    addTreeSitterGrammar(b, exe_module, "tree-sitter-yaml");
    addTreeSitterGrammar(b, exe_module, "tree-sitter-json");

    const exe = b.addExecutable(.{
        .name = "flamingo",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ── Test step ─────────────────────────────────────────────────────────────
    // All test files are referenced from src/main.zig's `test` block, so a
    // single addTest step rooted at the exe module discovers everything.
    const test_step = b.step("test", "Run all tests");
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib_tests.root_module.addImport("logz", logz);
    lib_tests.root_module.addImport("toml", toml);
    lib_tests.root_module.addImport("tree-sitter", tree_sitter.module("tree_sitter"));
    addTreeSitterGrammar(b, lib_tests.root_module, "tree-sitter-zig");
    addTreeSitterGrammar(b, lib_tests.root_module, "tree-sitter-go");
    addTreeSitterGrammar(b, lib_tests.root_module, "tree-sitter-toml");
    addTreeSitterGrammar(b, lib_tests.root_module, "tree-sitter-yaml");
    addTreeSitterGrammar(b, lib_tests.root_module, "tree-sitter-json");

    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}

fn addTreeSitterGrammar(b: *std.Build, module: *std.Build.Module, comptime name: []const u8) void {
    const root = "vendor/" ++ name;
    module.addIncludePath(b.path(root ++ "/src"));
    module.addCSourceFile(.{
        .file = b.path(root ++ "/src/parser.c"),
        .flags = &.{"-std=c11"},
    });

    if (comptime std.mem.eql(u8, name, "tree-sitter-toml") or std.mem.eql(u8, name, "tree-sitter-yaml")) {
        module.addCSourceFile(.{
            .file = b.path(root ++ "/src/scanner.c"),
            .flags = &.{"-std=c11"},
        });
    }
}
