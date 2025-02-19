const std = @import("std");
const Command = @import("../cli.zig").Command;
const bun = @import("bun");
const string = bun.string;
const Output = bun.Output;
const Global = bun.Global;
const Environment = bun.Environment;
const strings = bun.strings;
const MutableString = bun.MutableString;
const stringZ = bun.stringZ;
const default_allocator = bun.default_allocator;
const C = bun.C;

const lex = bun.js_lexer;
const logger = @import("bun").logger;

const options = @import("../options.zig");
const js_parser = bun.js_parser;
const json_parser = bun.JSON;
const js_printer = bun.js_printer;
const js_ast = bun.JSAst;
const linker = @import("../linker.zig");

const sync = @import("../sync.zig");
const Api = @import("../api/schema.zig").Api;
const resolve_path = @import("../resolver/resolve_path.zig");
const configureTransformOptionsForBun = @import("../bun.js/config.zig").configureTransformOptionsForBun;
const bundler = bun.bundler;
const NodeModuleBundle = @import("../node_module_bundle.zig").NodeModuleBundle;
const GenerateNodeModuleBundle = @import("../bundler/generate_node_modules_bundle.zig");
const DotEnv = @import("../env_loader.zig");

const fs = @import("../fs.zig");
const Router = @import("../router.zig");
const BundleV2 = @import("../bundler/bundle_v2.zig").BundleV2;
var estimated_input_lines_of_code_: usize = undefined;

pub const BuildCommand = struct {
    pub fn exec(
        ctx: Command.Context,
    ) !void {
        Global.configureAllocator(.{ .long_running = true });
        var allocator = ctx.allocator;
        var log = ctx.log;
        estimated_input_lines_of_code_ = 0;

        var this_bundler = try bundler.Bundler.init(allocator, log, ctx.args, null, null);
        this_bundler.options.entry_names = ctx.bundler_options.entry_names;
        this_bundler.resolver.opts.entry_names = ctx.bundler_options.entry_names;
        this_bundler.options.output_dir = ctx.bundler_options.outdir;
        this_bundler.resolver.opts.output_dir = ctx.bundler_options.outdir;
        this_bundler.options.react_server_components = ctx.bundler_options.react_server_components;
        this_bundler.resolver.opts.react_server_components = ctx.bundler_options.react_server_components;
        this_bundler.options.code_splitting = ctx.bundler_options.code_splitting;
        this_bundler.resolver.opts.code_splitting = ctx.bundler_options.code_splitting;

        this_bundler.configureLinker();

        // This step is optional
        // If it fails for any reason, ignore it and continue bundling
        // This is partially a workaround for the 'error.MissingRoutesDir' error
        this_bundler.configureRouter(true) catch {
            this_bundler.options.routes.routes_enabled = false;
            this_bundler.options.framework = null;
            if (this_bundler.router) |*router| {
                router.config.routes_enabled = false;
                router.config.single_page_app_routing = false;
                router.config.static_dir_enabled = false;
                this_bundler.router = null;
            }
            this_bundler.options.node_modules_bundle = null;
            this_bundler.options.node_modules_bundle_pretty_path = "";
            this_bundler.options.node_modules_bundle_url = "";
        };

        if (ctx.debug.macros) |macros| {
            this_bundler.options.macro_remap = macros;
        }

        // var env_loader = this_bundler.env;

        if (ctx.debug.dump_environment_variables) {
            this_bundler.dumpEnvironmentVariables();
            return;
        }

        if (ctx.debug.dump_limits) {
            fs.FileSystem.printLimits();
            Global.exit(0);
            return;
        }

        const output_files: []options.OutputFile = brk: {
            if (ctx.bundler_options.transform_only) {
                this_bundler.linker.options.resolve_mode = .lazy;
                this_bundler.options.import_path_format = .relative;

                // TODO: refactor this .transform function
                const result = try this_bundler.transform(
                    ctx.allocator,
                    ctx.log,
                    ctx.args,
                );
                try log.msgs.appendSlice(result.errors);
                try log.msgs.appendSlice(result.warnings);
                break :brk result.output_files;
            }

            break :brk (BundleV2.generate(
                &this_bundler,
                allocator,
                &estimated_input_lines_of_code_,
                ctx.debug.package_bundle_map,
                bun.JSC.AnyEventLoop.init(ctx.allocator),
                std.crypto.random.int(u64),
                ctx.debug.hot_reload == .watch,
            ) catch |err| {
                if (log.msgs.items.len > 0) {
                    try log.printForLogLevel(Output.errorWriter());
                } else {
                    try Output.errorWriter().print("error: {s}", .{@errorName(err)});
                }

                Output.flush();
                exitOrWatch(1, ctx.debug.hot_reload == .watch);
                unreachable;
            }).items;
        };

        {
            {
                dump: {
                    defer Output.flush();
                    var writer = Output.errorWriter();
                    var output_dir = this_bundler.options.output_dir;
                    if (ctx.bundler_options.outfile.len > 0 and output_files.len == 1 and output_files[0].value == .buffer) {
                        output_dir = std.fs.path.dirname(ctx.bundler_options.outfile) orelse ".";
                        output_files[0].input.text = std.fs.path.basename(ctx.bundler_options.outfile);
                    }

                    if (output_dir.len == 0 and ctx.bundler_options.outfile.len == 0) {
                        // if --transform is passed, it won't have an output dir
                        if (output_files[0].value == .buffer)
                            try writer.writeAll(output_files[0].value.buffer);
                        break :dump;
                    }

                    const root_path = output_dir;
                    const root_dir = try std.fs.cwd().makeOpenPathIterable(root_path, .{});
                    var all_paths = try ctx.allocator.alloc([]const u8, output_files.len);
                    var max_path_len: usize = 0;
                    for (all_paths, output_files) |*dest, src| {
                        dest.* = src.input.text;
                    }

                    var from_path = resolve_path.longestCommonPath(all_paths);

                    for (output_files) |f| {
                        max_path_len = std.math.max(
                            std.math.max(from_path.len, f.input.text.len) + 2 - from_path.len,
                            max_path_len,
                        );
                    }

                    // On posix, file handles automatically close on process exit by the OS
                    // Closing files shows up in profiling.
                    // So don't do that unless we actually need to.
                    // const do_we_need_to_close = !FeatureFlags.store_file_descriptors or (@intCast(usize, root_dir.fd) + open_file_limit) < output_files.len;

                    var filepath_buf: [bun.MAX_PATH_BYTES]u8 = undefined;
                    filepath_buf[0] = '.';
                    filepath_buf[1] = '/';

                    for (output_files) |f| {
                        var rel_path: []const u8 = undefined;
                        switch (f.value) {
                            // easy mode: write the buffer
                            .buffer => |value| {
                                rel_path = f.input.text;
                                if (f.input.text.len > from_path.len) {
                                    rel_path = resolve_path.relative(from_path, f.input.text);
                                    if (std.fs.path.dirname(rel_path)) |parent| {
                                        if (parent.len > root_path.len) {
                                            try root_dir.dir.makePath(parent);
                                        }
                                    }
                                }
                                try root_dir.dir.writeFile(rel_path, value);
                            },
                            .move => |value| {
                                const primary = f.input.text[from_path.len..];
                                bun.copy(u8, filepath_buf[2..], primary);
                                rel_path = filepath_buf[0 .. primary.len + 2];
                                rel_path = value.pathname;

                                try f.moveTo(root_path, bun.constStrToU8(rel_path), root_dir.dir.fd);
                            },
                            .copy => |value| {
                                rel_path = value.pathname;

                                try f.copyTo(root_path, bun.constStrToU8(rel_path), root_dir.dir.fd);
                            },
                            .noop => {},
                            .pending => unreachable,
                        }

                        // Print summary
                        _ = try writer.write("\n");
                        const padding_count = 2 + (std.math.max(rel_path.len, max_path_len) - rel_path.len);
                        try writer.writeByteNTimes(' ', 2);
                        try writer.writeAll(rel_path);
                        try writer.writeByteNTimes(' ', padding_count);
                        const size = @intToFloat(f64, f.size) / 1000.0;
                        try std.fmt.formatFloatDecimal(size, .{ .precision = 2 }, writer);
                        try writer.writeAll(" KB\n");
                    }
                }
            }
            try log.printForLogLevel(Output.errorWriter());
            exitOrWatch(0, ctx.debug.hot_reload == .watch);
        }
    }
};

fn exitOrWatch(code: u8, watch: bool) void {
    if (watch) {
        // the watcher thread will exit the process
        std.time.sleep(std.math.maxInt(u64) - 1);
    }
    Global.exit(code);
}
