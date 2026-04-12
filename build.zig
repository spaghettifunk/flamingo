const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // nanoarrow static library
    const nanoarrow = b.addLibrary(.{
        .name = "nanoarrow",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    nanoarrow.addCSourceFile(.{
        .file = b.path("vendor/nanoarrow/nanoarrow.c"),
        .flags = &.{"-std=c99"},
    });
    nanoarrow.addIncludePath(b.path("vendor/nanoarrow"));
    nanoarrow.linkLibC();

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

    // Chilli CLI dependency
    const chilli = b.dependency("chilli", .{
        .target = target,
        .optimize = optimize,
    }).module("chilli");

    // DuckDB dependency via zuckdb
    const zuckdb = b.dependency("zuckdb", .{
        .target = target,
        .optimize = optimize,
        .system_libduckdb = false,
        .debug_duckdb = false,
    }).module("zuckdb");

    // HTTP webserver
    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    }).module("httpz");

    // OpenTelemetry proto package ships protobuf as a dependency so we'll use it.
    const otel_pb_dep = b.dependency("opentelemetry_proto", .{
        .optimize = optimize,
        .target = target,
    });
    const otel_proto_mod = otel_pb_dep.module("opentelemetry-proto");
    const protobuf_mod = otel_pb_dep.builder.dependency("protobuf", .{
        .optimize = optimize,
        .target = target,
    }).module("protobuf");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_module.addImport("logz", logz);
    exe_module.addImport("toml", toml);
    exe_module.addImport("chilli", chilli);
    exe_module.addImport("zuckdb", zuckdb);
    exe_module.addImport("httpz", httpz);
    exe_module.addImport("protobuf", protobuf_mod);
    exe_module.addImport("opentelemetry-proto", otel_proto_mod);

    const exe = b.addExecutable(.{
        .name = "flamingo",
        .root_module = exe_module,
    });

    exe.linkLibrary(nanoarrow);
    exe.addIncludePath(b.path("vendor/nanoarrow"));
    exe.linkLibC();

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
