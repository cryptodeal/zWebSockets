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

    // zSockets module, with all build options
    const zsockets_module = b.dependency("zSockets", .{
        .target = target,
        .optimize = optimize,
        .WITH_IO_URING = b.option(bool, "WITH_IO_URING", "builds with io_uring as event-loop and network implementation") orelse false,
        .WITH_LIBUV = b.option(bool, "WITH_LIBUV", "builds with libuv as event-loop") orelse false,
        .WITH_ASIO = b.option(bool, "WITH_ASIO", "builds with boot ASIO as event-loop") orelse false,
        .WITH_GCD = b.option(bool, "WITH_GCD", "builds with libdispatch as event-loop") orelse false,
        .WITH_EPOLL = b.option(bool, "WITH_EPOLL", "builds with epoll as event-loop") orelse false,
        .WITH_KQUEUE = b.option(bool, "WITH_KQUEUE", "builds with kqueue as event-loop") orelse false,
        .WITH_QUIC = b.option(bool, "WITH_QUIC", "builds with QUIC network implementation") orelse false,
        .WITH_BORINGSSL = b.option(bool, "WITH_BORINGSSL", "enables BoringSSL support, linked statically (preferred over OpenSSL)") orelse false,
        .WITH_OPENSSL = b.option(bool, "WITH_OPENSSL", "enables OpenSSL 1.1+ support") orelse false,
        .WITH_WOLFSSL = b.option(bool, "WITH_WOLFSSL", "enables WolfSSL 4.2.0 support (mutually exclusive with OpenSSL)") orelse false,
    }).module("zSockets");

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
            .{ .name = "zSockets", .module = zsockets_module },
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
    env_options.addOption(bool, "use_simdutf", b.option(bool, "USE_SIMDUTF", "Enables support for simdutf") orelse false);
    env_options.addOption(bool, "with_proxy", b.option(bool, "WITH_PROXY", "Enables PROXY Protocol v2 support") orelse false);
    env_options.addOption(usize, "http_max_headers_size", b.option(usize, "HTTP_MAX_HEADERS_SIZE", "Specify the maximum size of headers handled; defaults to 4096") orelse 4096);
    env_options.addOption(usize, "http_max_headers_count", b.option(usize, "HTTP_MAX_HEADERS_COUNT", "Specify the maximum number of headers handled; defaults to 100") orelse 100);
    env_options.addOption(bool, "remote_address_userspace", b.option(bool, "REMOTE_ADDRESS_USERSPACE", "Enables remote address userspace functionality") orelse false);
    env_options.addOption(bool, "httpresponse_no_writemark", b.option(bool, "HTTPRESPONSE_NO_WRITEMARK", "Optionally prevent sending zWebSockets header") orelse false);

    mod.addOptions("env", env_options);

    const broadcast_exe = b.addExecutable(.{
        .name = "broadcast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/broadcast.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const broadcast_run_step = b.step("broadcast", "Run the broadcast example");
    const broadcast_install_cmd = b.addInstallArtifact(broadcast_exe, .{});
    broadcast_run_step.dependOn(&broadcast_install_cmd.step);
    const broadcast_run_cmd = b.addRunArtifact(broadcast_exe);
    broadcast_run_step.dependOn(&broadcast_run_cmd.step);
    broadcast_run_cmd.step.dependOn(b.getInstallStep());

    const broadcasting_echo_server_exe = b.addExecutable(.{
        .name = "broadcasting_echo_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/broadcasting_echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const broadcasting_echo_server_run_step = b.step("broadcasting_echo_server", "Run the broadcasting echo server example");
    const broadcasting_echo_server_install_cmd = b.addInstallArtifact(broadcasting_echo_server_exe, .{});
    broadcasting_echo_server_run_step.dependOn(&broadcasting_echo_server_install_cmd.step);
    const broadcasting_echo_server_run_cmd = b.addRunArtifact(broadcasting_echo_server_exe);
    broadcasting_echo_server_run_step.dependOn(&broadcasting_echo_server_run_cmd.step);
    broadcasting_echo_server_run_cmd.step.dependOn(b.getInstallStep());

    const hello_world_exe = b.addExecutable(.{
        .name = "hello_world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello_world.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const hello_world_run_step = b.step("hello_world", "Run the hello world example");
    const hello_world_install_cmd = b.addInstallArtifact(hello_world_exe, .{});
    broadcast_run_step.dependOn(&hello_world_install_cmd.step);
    const hello_world_run_cmd = b.addRunArtifact(hello_world_exe);
    hello_world_run_step.dependOn(&hello_world_run_cmd.step);
    hello_world_run_cmd.step.dependOn(b.getInstallStep());

    const crc32_exe = b.addExecutable(.{
        .name = "crc32",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/crc32.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const crc32_run_step = b.step("crc32", "Run the crc32 example");
    const crc32_install_cmd = b.addInstallArtifact(crc32_exe, .{});
    crc32_run_step.dependOn(&crc32_install_cmd.step);
    const crc32_run_cmd = b.addRunArtifact(crc32_exe);
    crc32_run_step.dependOn(&crc32_run_cmd.step);
    crc32_run_cmd.step.dependOn(b.getInstallStep());

    const echo_body_exe = b.addExecutable(.{
        .name = "echo_body",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_body.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });
    b.installArtifact(echo_body_exe);

    const echo_body_run_step = b.step("echo_body", "Run the echo body example");
    const echo_body_install_cmd = b.addInstallArtifact(echo_body_exe, .{});
    echo_body_run_step.dependOn(&echo_body_install_cmd.step);
    const echo_body_run_cmd = b.addRunArtifact(echo_body_exe);
    echo_body_run_step.dependOn(&echo_body_run_cmd.step);
    echo_body_run_cmd.step.dependOn(b.getInstallStep());

    const echo_server_exe = b.addExecutable(.{
        .name = "echo_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const echo_server_run_step = b.step("echo_server", "Run the echo server example");
    const echo_server_install_cmd = b.addInstallArtifact(echo_server_exe, .{});
    echo_server_run_step.dependOn(&echo_server_install_cmd.step);
    const echo_server_run_cmd = b.addRunArtifact(echo_server_exe);
    echo_server_run_step.dependOn(&echo_server_run_cmd.step);
    echo_server_run_cmd.step.dependOn(b.getInstallStep());

    const hello_world_threaded_exe = b.addExecutable(.{
        .name = "hello_world_threaded",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello_world_threaded.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const hello_world_threaded_run_step = b.step("hello_world_threaded", "Run the hello world threaded example");
    const hello_world_threaded_install_cmd = b.addInstallArtifact(hello_world_threaded_exe, .{});
    hello_world_threaded_run_step.dependOn(&hello_world_threaded_install_cmd.step);
    const hello_world_threaded_run_cmd = b.addRunArtifact(hello_world_threaded_exe);
    hello_world_threaded_run_step.dependOn(&hello_world_threaded_run_cmd.step);
    hello_world_threaded_run_cmd.step.dependOn(b.getInstallStep());

    const parameter_routes_exe = b.addExecutable(.{
        .name = "parameter_routes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parameter_routes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const parameter_routes_run_step = b.step("parameter_routes", "Run the parameter routes example");
    const parameter_routes_install_cmd = b.addInstallArtifact(parameter_routes_exe, .{});
    parameter_routes_run_step.dependOn(&parameter_routes_install_cmd.step);
    const parameter_routes_run_cmd = b.addRunArtifact(parameter_routes_exe);
    parameter_routes_run_step.dependOn(&parameter_routes_run_cmd.step);
    parameter_routes_run_cmd.step.dependOn(b.getInstallStep());

    const precompress_exe = b.addExecutable(.{
        .name = "precompress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/precompress.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const precompress_run_step = b.step("precompress", "Run the precompress example");
    const precompress_install_cmd = b.addInstallArtifact(precompress_exe, .{});
    precompress_run_step.dependOn(&precompress_install_cmd.step);
    const precompress_run_cmd = b.addRunArtifact(precompress_exe);
    precompress_run_step.dependOn(&precompress_run_cmd.step);
    precompress_run_cmd.step.dependOn(b.getInstallStep());

    const server_name_exe = b.addExecutable(.{
        .name = "server_name",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/server_name.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
            },
        }),
    });

    const server_name_run_step = b.step("server_name", "Run the server name example");
    const server_name_install_cmd = b.addInstallArtifact(server_name_exe, .{});
    server_name_run_step.dependOn(&server_name_install_cmd.step);
    const server_name_run_cmd = b.addRunArtifact(server_name_exe);
    server_name_run_step.dependOn(&server_name_run_cmd.step);
    server_name_run_cmd.step.dependOn(b.getInstallStep());

    const secure_gzip_file_server_exe = b.addExecutable(.{
        .name = "secure_gzip_file_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/secure_gzip_file_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
                .{ .name = "args", .module = b.dependency("args", .{ .target = target, .optimize = optimize }).module("args") },
            },
        }),
    });

    const secure_gzip_file_server_run_step = b.step("secure_gzip_file_server", "Run the secure gzip file server example");
    const secure_gzip_file_server_install_cmd = b.addInstallArtifact(secure_gzip_file_server_exe, .{});
    secure_gzip_file_server_run_step.dependOn(&secure_gzip_file_server_install_cmd.step);
    const secure_gzip_file_server_run_cmd = b.addRunArtifact(secure_gzip_file_server_exe);
    secure_gzip_file_server_run_step.dependOn(&secure_gzip_file_server_run_cmd.step);
    secure_gzip_file_server_run_cmd.step.dependOn(b.getInstallStep());

    const upgrade_async_exe = b.addExecutable(.{
        .name = "upgrade_async",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/upgrade_async.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
                .{ .name = "args", .module = b.dependency("args", .{ .target = target, .optimize = optimize }).module("args") },
            },
        }),
    });

    const upgrade_async_run_step = b.step("upgrade_async", "Run the upgrade async example");
    const upgrade_async_install_cmd = b.addInstallArtifact(upgrade_async_exe, .{});
    upgrade_async_run_step.dependOn(&upgrade_async_install_cmd.step);
    const upgrade_async_run_cmd = b.addRunArtifact(upgrade_async_exe);
    upgrade_async_run_step.dependOn(&upgrade_async_run_cmd.step);
    upgrade_async_run_cmd.step.dependOn(b.getInstallStep());

    const upgrade_sync_exe = b.addExecutable(.{
        .name = "upgrade_sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/upgrade_sync.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
                .{ .name = "args", .module = b.dependency("args", .{ .target = target, .optimize = optimize }).module("args") },
            },
        }),
    });

    const upgrade_sync_run_step = b.step("upgrade_sync", "Run the upgrade sync example");
    const upgrade_sync_install_cmd = b.addInstallArtifact(upgrade_sync_exe, .{});
    upgrade_sync_run_step.dependOn(&upgrade_sync_install_cmd.step);
    const upgrade_sync_run_cmd = b.addRunArtifact(upgrade_sync_exe);
    upgrade_sync_run_step.dependOn(&upgrade_sync_run_cmd.step);
    upgrade_sync_run_cmd.step.dependOn(b.getInstallStep());

    const http_cache_exe = b.addExecutable(.{
        .name = "http_cache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http_cache.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zWebSockets", .module = mod },
                .{ .name = "zSockets", .module = zsockets_module },
                .{ .name = "args", .module = b.dependency("args", .{ .target = target, .optimize = optimize }).module("args") },
            },
        }),
    });

    const http_cache_run_step = b.step("http_cache", "Run the upgrade sync example");
    const http_cache_install_cmd = b.addInstallArtifact(http_cache_exe, .{});
    http_cache_run_step.dependOn(&http_cache_install_cmd.step);
    const http_cache_run_cmd = b.addRunArtifact(http_cache_exe);
    http_cache_run_step.dependOn(&http_cache_run_cmd.step);
    http_cache_run_cmd.step.dependOn(b.getInstallStep());

    const examples_ci_build_step = b.step("examples", "Build examples for CI");
    const crc32_ci_install = b.addInstallArtifact(crc32_exe, .{});
    const echo_body_ci_install = b.addInstallArtifact(echo_body_exe, .{});
    examples_ci_build_step.dependOn(&crc32_ci_install.step);
    examples_ci_build_step.dependOn(&echo_body_ci_install.step);

    if (b.args) |args| {
        broadcast_run_cmd.addArgs(args);
        broadcasting_echo_server_run_cmd.addArgs(args);
        hello_world_run_cmd.addArgs(args);
        crc32_run_cmd.addArgs(args);
        echo_body_run_cmd.addArgs(args);
        echo_server_run_cmd.addArgs(args);
        hello_world_threaded_run_cmd.addArgs(args);
        parameter_routes_run_cmd.addArgs(args);
        precompress_run_cmd.addArgs(args);
        server_name_run_cmd.addArgs(args);
        secure_gzip_file_server_run_cmd.addArgs(args);
        upgrade_async_run_cmd.addArgs(args);
        upgrade_sync_run_cmd.addArgs(args);
        http_cache_run_cmd.addArgs(args);
    }

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
