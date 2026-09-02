const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const with_libdeflate = b.option(bool, "WITH_LIBDEFLATE", "Use libdeflate as a fast path to zlib (you need to build it first)") orelse false;
    const with_zlib = b.option(bool, "WITH_ZLIB", "By default we use zlib but you can build without it (disables permessage-deflate)") orelse true;

    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zWebSockets", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "zSockets", .module = b.dependency("zSockets", .{ .target = target, .optimize = optimize }).module("zSockets") },
        },
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // link libdeflate
    if (with_libdeflate) if (b.lazyDependency("libdeflate", .{ .target = target, .optimize = optimize })) |libdeflate_dep| {
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/c/_libdeflate.h"),
            .target = target,
            .optimize = optimize,
        });
        const libdeflate = libdeflate_dep.artifact("deflate");
        translate_c.addIncludePath(libdeflate.getEmittedIncludeTree());
        mod.linkLibrary(libdeflate);
        mod.addImport("libdeflate", translate_c.createModule());
    };
    // link zlib
    if (with_zlib) if (b.lazyDependency("zlib", .{ .target = target, .optimize = optimize })) |zlib_dep| {
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/c/_zlib.h"),
            .target = target,
            .optimize = optimize,
        });
        const zlib = zlib_dep.artifact("z");
        translate_c.addIncludePath(zlib.getEmittedIncludeTree());
        mod.linkLibrary(zlib);
        mod.addImport("zlib", translate_c.createModule());
    };

    const env_options = b.addOptions();
    env_options.addOption(bool, "with_libdeflate", with_libdeflate);
    env_options.addOption(bool, "with_zlib", with_zlib);
    env_options.addOption(bool, "mock_zlib", b.option(bool, "MOCK_ZLIB", "Enabled for fuzzing the implementation") orelse false);

    env_options.addOption(bool, "with_proxy", b.option(bool, "WITH_PROXY", "Enables PROXY Protocol v2 support") orelse false);
    env_options.addOption(usize, "http_max_headers_size", b.option(usize, "HTTP_MAX_HEADERS_SIZE", "Specify the maximum size of headers handled; defaults to 4096") orelse 4096);
    env_options.addOption(usize, "http_max_headers_count", b.option(usize, "HTTP_MAX_HEADERS_COUNT", "Specify the maximum number of headers handled; defaults to 100") orelse 100);
    env_options.addOption(bool, "remote_address_userspace", b.option(bool, "REMOTE_ADDRESS_USERSPACE", "Enables remote address userspace functionality") orelse false);
    env_options.addOption(bool, "httpresponse_no_writemark", b.option(bool, "HTTPRESPONSE_NO_WRITEMARK", "Optionally prevent sending zWebSockets header") orelse false);

    mod.addOptions("env", env_options);

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
