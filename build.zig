// SPDX-License-Identifier: LGPL-2.0-or-later
//! regex-zig build script. `zig build test` runs all unit tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The Unicode tables (\p{..}, Unicode \w \d \s \b, case folding) are
    // about 225 KB of source and are linked into every program that uses the
    // library. Turn them off with -Dunicode_tables=false; utf8 mode then keeps
    // ASCII-only classes and ASCII-only case folding, and \p{..} is rejected.
    const unicode_tables = b.option(
        bool,
        "unicode_tables",
        "Embed the Unicode property and case-folding tables (default: true)",
    ) orelse true;
    const options = b.addOptions();
    options.addOption(bool, "unicode_tables", unicode_tables);

    // The library module, importable by consumers as @import("regex").
    const mod = b.addModule("regex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);

    // Benchmarks are always built with ReleaseFast so numbers are meaningful.
    const bench_regex = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_regex.addOptions("build_options", options);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "regex", .module = bench_regex }},
        }),
    });
    const bench_step = b.step("bench", "Run benchmarks (ReleaseFast)");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    const test_step = b.step("test", "Run Zig unit tests");
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this");
    const unit = b.addTest(.{
        .root_module = mod,
        .filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}
