//! go-dev extension — a single "go" tool + a "go-dev" subagent preset.
//!
//! This module is a Tier-1 franky extension that registers one Go tool
//! (`go`) and a subagent preset named `"go-dev"` that bundles it
//! alongside the standard file and shell tools.
//!
//! ## Usage (standalone binary via SDK)
//!
//! Register via the franky SDK's `ext_catalog` before delegating to the
//! mode driver. The extension's init_fn wires tools, presets, and slash
//! commands automatically:
//!
//! ```zig
//! const go_dev = @import("franky-golang");
//! try franky.ext_catalog.register("go-dev", go_dev.extension);
//! try franky.coding.modes.print.run(gpa, io, environ, environ_map, argv);
//! ```
//!
//! Activate with `--extensions go-dev` on the CLI. Both print and
//! interactive modes are supported out of the box — no forking of the
//! mode driver needed.
//!
//! ## Fallback: standalone preset registration (no extension system)
//!
//! When the mode driver does NOT load extensions (pre-SDK code),
//! register the preset directly:
//!
//! ```zig
//! const go_dev = @import("franky-golang");
//! try go_dev.registerPreset(&preset_registry);
//! // Then preset_registry.get("go-dev") returns the preset.
//! ```
//!
//! ## Tool schema
//!
//! | Tool | Description | Required args |
//! |------|-------------|---------------|
//! | `go`  | Run `go fmt` / `go vet` / `go build` / `go test` | `command` (string), `path` (string; file, directory, or ./...), `flags` (string, optional), `cwd` (string, optional) |

const std = @import("std");
const franky = @import("franky");

const at = franky.agent.types;
const ai = franky.ai.types;
const subagent_mod = franky.coding.tools.subagent;
const ext = franky.coding.extensions;

// ─── Tool executor ───────────────────────────────────────────────────
//
// Dispatches to one of four sub-tools based on the `command` field:
//   "fmt"   → gofmt -d <path>        (file, directory, or ./...)
//   "vet"   → go vet <path>          (package path or ./...)
//   "build" → go build <path>        (package path or ./...)
//   "test"  → go test [flags] <path> (package path or ./...)
//
// Error results use structured tool_code values:
//   go_cmd_not_found, go_fmt_failed,
//   go_vet_failed, go_build_failed, go_test_failed.

/// Build a structured failure ToolResult with a tool_code subcode.
/// Mirrors franky's coding/tools/common.zig:toolError but duplicated
/// here so this module has no dependency on franky internals beyond
/// the public API types.
fn toolError(allocator: std.mem.Allocator, code: []const u8, comptime fmt: []const u8, args: anytype) !at.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "[{s}] " ++ fmt, .{code} ++ args);
    const arr = try allocator.alloc(ai.ContentBlock, 1);
    errdefer allocator.free(arr);
    arr[0] = .{ .text = .{ .text = text } };
    const code_dup = try allocator.dupe(u8, code);
    errdefer allocator.free(code_dup);
    return .{ .content = arr, .is_error = true, .tool_code = code_dup };
}

const GoArgs = struct {
    command: []const u8,
    path: []const u8,
    flags: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

fn goExecute(
    self: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    call_id: []const u8,
    args_json: []const u8,
    cancel: *franky.ai.stream.Cancel,
    on_update: at.OnUpdate,
) anyerror!at.ToolResult {
    _ = self;
    _ = call_id;
    _ = cancel;
    _ = on_update;

    const args = try std.json.parseFromSlice(GoArgs, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer args.deinit();

    const command = args.value.command;
    const path = args.value.path;

    // ── go fmt ────────────────────────────────────────────────────
    // gofmt works with .go files, directories, and ./... patterns.
    // We don't validate the path here — gofmt reports its own errors.
    if (std.mem.eql(u8, command, "fmt")) {
        const result = std.process.run(allocator, io, .{
            .argv = &[_][]const u8{ "gofmt", "-d", path },
        }) catch |err| {
            if (err == error.FileNotFound) {
                return toolError(allocator, "go_fmt_not_found", "gofmt command not found. Is Go installed and in your PATH?", .{});
            }
            return toolError(allocator, "go_fmt_spawn_failed", "{s}", .{@errorName(err)});
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.exited != 0) {
            return toolError(allocator, "go_fmt_failed", "gofmt -d {s} exited with code {d}:\n{s}", .{ path, result.term.exited, result.stderr });
        }

        const text = if (result.stdout.len == 0)
            try allocator.dupe(u8, "File is already formatted.")
        else
            try allocator.dupe(u8, result.stdout);

        const arr = try allocator.alloc(ai.ContentBlock, 1);
        arr[0] = .{ .text = .{ .text = text } };
        return .{ .content = arr, .is_error = false };
    }

    // ── go vet, go build, go test ─────────────────────────────────
    const is_go_cmd = std.mem.eql(u8, command, "vet") or
        std.mem.eql(u8, command, "build") or
        std.mem.eql(u8, command, "test");

    if (!is_go_cmd) {
        return toolError(allocator, "go_unknown_command", "unknown command '{s}'. Must be one of: fmt, vet, build, test", .{command});
    }

    // Build argv: go <command> [flags...] <path>
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);

    try argv_list.appendSlice(allocator, &[_][]const u8{ "go", command });

    if (std.mem.eql(u8, command, "test")) {
        if (args.value.flags) |f| {
            var it = std.mem.splitScalar(u8, f, ' ');
            while (it.next()) |flag| {
                if (flag.len > 0) {
                    try argv_list.append(allocator, flag);
                }
            }
        }
    }

    try argv_list.append(allocator, path);

    const result = std.process.run(allocator, io, .{
        .argv = argv_list.items,
        .cwd = if (args.value.cwd) |c| .{ .path = c } else .inherit,
    }) catch |err| {
        if (err == error.FileNotFound) {
            return toolError(allocator, "go_cmd_not_found", "go command not found. Is Go installed and in your PATH?", .{});
        }
        return toolError(allocator, "go_spawn_failed", "{s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const output = try std.fmt.allocPrint(allocator, "STDOUT:\n{s}\nSTDERR:\n{s}", .{ result.stdout, result.stderr });

    if (result.term.exited != 0) {
        defer allocator.free(output);
        const code = if (std.mem.eql(u8, command, "vet")) "go_vet_failed"
            else if (std.mem.eql(u8, command, "build")) "go_build_failed"
            else "go_test_failed";
        return toolError(allocator, code, "go {s} {s} exited with code {d}:\n{s}", .{ command, path, result.term.exited, output });
    }

    // For vet/build, a zero-exit with no output is success.
    if (output.len == 0) {
        const arr = try allocator.alloc(ai.ContentBlock, 1);
        arr[0] = .{ .text = .{ .text = try allocator.dupe(u8, "`go {s}` completed successfully with no output.") } };
        return .{ .content = arr, .is_error = false };
    }

    const arr = try allocator.alloc(ai.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = output } };
    return .{ .content = arr, .is_error = false };
}

// ─── Tool factory function ───────────────────────────────────────────

pub fn goTool() at.AgentTool {
    return .{
        .name = "go",
        .description = "Run Go tool commands: fmt, vet, build, or test. Use `command` to select the sub-tool and `path` for the file (fmt) or package (vet/build/test).",
        .parameters_json =
        \\{"type":"object","required":["command","path"],"properties":{
        \\"command":{"type":"string","enum":["fmt","vet","build","test"],"description":"Go sub-command to run"},
        \\"path":{"type":"string","description":"File, directory, or ./... pattern (any sub-command)"},
        \\"flags":{"type":"string","description":"Additional flags for test (optional, e.g. -v -race)"},
        \\"cwd":{"type":"string","description":"Working directory (optional)"}
        \\}}
        ,
        .execution_mode = .sequential,
        .execute = goExecute,
    };
}

// ─── Preset builder ──────────────────────────────────────────────────
//
// Builds the tool list for the "go-dev" subagent preset. It selects
// parent-wired tools by name (read, write, edit, ls, bash, grep) and
// appends the single custom Go tool stub.

fn buildGoDevTools(
    allocator: std.mem.Allocator,
    parent_tools: []const at.AgentTool,
) anyerror![]at.AgentTool {
    // Step 1: select parent-wired tools by name
    const selected = try selectTools(allocator, parent_tools, &[_][]const u8{
        "read", "write", "edit", "ls", "bash", "grep",
    });
    errdefer allocator.free(selected);

    // Step 2: append the single Go tool stub
    const custom = [_]at.AgentTool{goTool()};

    const total = try allocator.alloc(at.AgentTool, selected.len + custom.len);
    @memcpy(total[0..selected.len], selected);
    @memcpy(total[selected.len..], &custom);
    allocator.free(selected);
    return total;
}

// ─── registerPreset helper (standalone) ──────────────────────────────
//
// Registers the "go-dev" preset into any PresetRegistry without going
// through the extension system. This is useful for mode drivers that
// don't load extensions (print, rpc, proxy) but still want the
// go-dev preset available.

pub fn registerPreset(registry: *subagent_mod.PresetRegistry) !void {
    try registry.register(.{
        .name = "go-dev",
        .description = "Go development: edit, format, vet, build, and test Go code.",
        .default_profile = "",
        .default_role = .code,
        .default_system_prompt =
        \\You are a Go development sub-agent. Your job is to help develop,
        \\review, and maintain Go code.
        \\
        \\You have the usual file tools (read, write, edit, ls, grep, bash)
        \\plus the "go" tool that dispatches fmt, vet, build, and test.
        \\
        \\Workflow:
        \\  1. Read the relevant files first to understand the codebase.
        \\  2. Make focused edits. Use edit over write for existing files.
        \\  3. Run `go` with command="fmt" on every Go file you create or modify.
        \\  4. Run `go` with command="vet" on affected packages after changes.
        \\  5. Run `go` with command="build" to check compilation.
        \\  6. Run `go` with command="test" to verify correctness.
        \\  7. Report what you did and what the tool output says.
        ,
        .build_tools = buildGoDevTools,
    });
}

// ─── Extension entry point (Tier-1) ──────────────────────────────────
//
// When loaded via `--extensions go-dev`, init_fn:
//   1. Registers the single Go tool stub with the host so the
//      parent LLM can call it directly.
//   2. Registers the "go-dev" preset via host.registerPreset() so
//      the subagent tool can spawn a Go-focused sub-agent.

pub fn extension() ext.Extension {
    return .{
        .name = "go-dev",
        .version = "0.2.0",
        .init_fn = init,
    };
}

fn init(_: *ext.Extension, host: *ext.Host) ext.ExtError!void {
    // Register the single custom tool so the parent LLM sees it.
    try host.registerTool(goTool());

    // Register the "go-dev" preset.
    // host.presets is set by the mode driver (via Manager.presets).
    // When null we silently no-op so the extension loads in modes
    // that haven't wired the preset hook yet (print, rpc, proxy),
    // albeit without registering the preset.
    if (host.presets) |registry| try registerPreset(registry);
}

// ─── Internal helpers ────────────────────────────────────────────────

/// Select tools from `parent_tools` by name. Mirrors the same-named
/// helper in subagent.zig but duplicated here so this module has no
/// dependency on franky's internal tool selection logic beyond the
/// public API types.
fn selectTools(
    allocator: std.mem.Allocator,
    parent_tools: []const at.AgentTool,
    names: []const []const u8,
) ![]at.AgentTool {
    var out = try allocator.alloc(at.AgentTool, names.len);
    var n: usize = 0;
    for (names) |want| {
        for (parent_tools) |t| {
            if (std.mem.eql(u8, t.name, want)) {
                out[n] = t;
                n += 1;
                break;
            }
        }
    }
    return allocator.realloc(out, n);
}

// ─── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

/// Returns true if a binary of the given name exists on PATH.
/// Used to skip tests that require Go/gofmt in CI environments
/// where these tools aren't installed.
fn haveBinary(name: []const u8) bool {
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    const result = std.process.run(gpa, io, .{
        .argv = &[_][]const u8{ name, "version" },
    }) catch |err| {
        // FileNotFound means the binary doesn't exist on PATH.
        // Any other error (e.g. non-zero exit) means it exists.
        return err != error.FileNotFound;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return true;
}

test "goTool returns a properly named AgentTool" {
    const t = goTool();
    try testing.expectEqualStrings("go", t.name);
    try testing.expect(t.description.len > 0);
    try testing.expect(t.parameters_json.len > 0);
    try testing.expect(t.execute == goExecute);
}

test "goExecute: fmt on badly formatted .go file returns diff" {
    if (!haveBinary("gofmt")) return error.SkipZigTest;
    const gpa = testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});
    const dir = tmp_dir.dir;

    const badly_formatted =
        \\package foo
        \\func Bar()   {}
        \\
    ;
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    try dir.writeFile(io, .{ .sub_path = "test.go", .data = badly_formatted });

    const abs_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/test.go", .{tmp_dir.sub_path});
    defer gpa.free(abs_path);

    const args_json = try std.fmt.allocPrint(gpa,
        \\{{"command":"fmt","path":"{s}"}}
    , .{abs_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    try testing.expect(!result.is_error);
    try testing.expect(result.content.len > 0);
    try testing.expect(result.content[0].text.text.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "test.go") != null);
}

test "goExecute: fmt on already formatted file returns no-diff message" {
    if (!haveBinary("gofmt")) return error.SkipZigTest;
    const gpa = testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});

    const well_formatted =
        \\package foo
        \\
        \\func Bar() {}
        \\
    ;
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "good.go", .data = well_formatted });

    const abs_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/good.go", .{tmp_dir.sub_path});
    defer gpa.free(abs_path);

    const args_json = try std.fmt.allocPrint(gpa,
        \\{{"command":"fmt","path":"{s}"}}
    , .{abs_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    try testing.expect(!result.is_error);
    try testing.expectEqualStrings("File is already formatted.", result.content[0].text.text);
}

test "goExecute: fmt on non-.go path runs gofmt which reports its own error" {
    if (!haveBinary("gofmt")) return error.SkipZigTest;
    const gpa = testing.allocator;
    const args_json = "{\"command\":\"fmt\",\"path\":\"/tmp/foo.txt\"}";
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    // gofmt runs on any path and reports its own error. The tool code
    // is go_fmt_failed, not go_fmt_not_a_go_file — we no longer
    // validate the extension before calling gofmt.
    try testing.expect(result.is_error);
    try testing.expect(result.tool_code != null);
    try testing.expectEqualStrings("go_fmt_failed", result.tool_code.?);
}

test "goExecute: fmt on non-existent path returns spawn error" {
    const gpa = testing.allocator;
    const args_json = "{\"command\":\"fmt\",\"path\":\"/tmp/nonexistent_dir_12345/test.go\"}";
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    try testing.expect(result.is_error);
    try testing.expect(result.tool_code != null);
}

test "goExecute: vet passes on well-formed package" {
    if (!haveBinary("go")) return error.SkipZigTest;
    const gpa = testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});

    var count: usize = 0;
    while (std.c.environ[count]) |_| { count += 1; }
    const env_slice: [:null]const ?[*:0]u8 = std.c.environ[0..count :null];
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .{ .block = .{ .slice = env_slice } } });
    defer threaded.deinit();
    const io = threaded.io();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module testpkg\n\ngo 1.24\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "main.go", .data =
        \\package testpkg
        \\
        \\func Hello() string { return "hello" }
        \\
    });

    const cwd_path = try std.fs.path.join(gpa, &[_][]const u8{ ".zig-cache", "tmp", tmp_dir.sub_path[0..] });
    defer gpa.free(cwd_path);
    const args_json = try std.fmt.allocPrint(gpa,
        \\{{"command":"vet","path":".","cwd":"{s}"}}
    , .{cwd_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    try testing.expect(!result.is_error);
}

test "goExecute: build compiles a valid package" {
    if (!haveBinary("go")) return error.SkipZigTest;
    const gpa = testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});

    var count: usize = 0;
    while (std.c.environ[count]) |_| { count += 1; }
    const env_slice: [:null]const ?[*:0]u8 = std.c.environ[0..count :null];
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .{ .block = .{ .slice = env_slice } } });
    defer threaded.deinit();
    const io = threaded.io();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module testpkg\n\ngo 1.24\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "main.go", .data =
        \\package main
        \\
        \\func main() {}
        \\
    });

    const cwd_path = try std.fs.path.join(gpa, &[_][]const u8{ ".zig-cache", "tmp", tmp_dir.sub_path[0..] });
    defer gpa.free(cwd_path);
    const args_json = try std.fmt.allocPrint(gpa,
        \\{{"command":"build","path":".","cwd":"{s}"}}
    , .{cwd_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    try testing.expect(!result.is_error);
}

test "goExecute: test passes on passing test" {
    if (!haveBinary("go")) return error.SkipZigTest;
    const gpa = testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});

    var count: usize = 0;
    while (std.c.environ[count]) |_| { count += 1; }
    const env_slice: [:null]const ?[*:0]u8 = std.c.environ[0..count :null];
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .{ .block = .{ .slice = env_slice } } });
    defer threaded.deinit();
    const io = threaded.io();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module testpkg\n\ngo 1.24\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "foo_test.go", .data =
        \\package testpkg
        \\
        \\import "testing"
        \\
        \\func TestPass(t *testing.T) {
        \\    t.Log("pass")
        \\}
        \\
    });

    const cwd_path = try std.fs.path.join(gpa, &[_][]const u8{ ".zig-cache", "tmp", tmp_dir.sub_path[0..] });
    defer gpa.free(cwd_path);
    const args_json = try std.fmt.allocPrint(gpa,
        \\{{"command":"test","path":".","cwd":"{s}"}}
    , .{cwd_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    try testing.expect(!result.is_error);
    try testing.expect(result.content.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "PASS") != null or
        std.mem.indexOf(u8, result.content[0].text.text, "ok") != null);
}

test "goExecute: failing test returns error with tool_code go_test_failed" {
    if (!haveBinary("go")) return error.SkipZigTest;
    const gpa = testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});

    var count: usize = 0;
    while (std.c.environ[count]) |_| { count += 1; }
    const env_slice: [:null]const ?[*:0]u8 = std.c.environ[0..count :null];
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .{ .block = .{ .slice = env_slice } } });
    defer threaded.deinit();
    const io = threaded.io();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module testpkg\n\ngo 1.24\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "fail_test.go", .data =
        \\package testpkg
        \\
        \\import "testing"
        \\
        \\func TestFail(t *testing.T) {
        \\    t.Error("expected failure")
        \\}
        \\
    });

    const cwd_path = try std.fs.path.join(gpa, &[_][]const u8{ ".zig-cache", "tmp", tmp_dir.sub_path[0..] });
    defer gpa.free(cwd_path);
    const args_json = try std.fmt.allocPrint(gpa,
        \\{{"command":"test","path":".","cwd":"{s}"}}
    , .{cwd_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    try testing.expect(result.is_error);
    try testing.expect(result.tool_code != null);
    try testing.expectEqualStrings("go_test_failed", result.tool_code.?);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "FAIL") != null);
}

test "goExecute: unknown command returns tool error" {
    const gpa = testing.allocator;
    const args_json = "{\"command\":\"unknown\",\"path\":\".\"}";
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cancel = franky.ai.stream.Cancel{};

    const tool = goTool();
    var result = try tool.execute(
        &tool,
        gpa,
        io,
        "test-call",
        args_json,
        &cancel,
        at.OnUpdate{},
    );
    defer result.deinit(gpa);

    try testing.expect(result.is_error);
    try testing.expect(result.tool_code != null);
    try testing.expectEqualStrings("go_unknown_command", result.tool_code.?);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "unknown") != null);
}

test "selectTools filters by name from parent slice" {
    const gpa = testing.allocator;
    const read_t: at.AgentTool = .{ .name = "read", .description = "", .parameters_json = "{}", .execute = undefined };
    const write_t: at.AgentTool = .{ .name = "write", .description = "", .parameters_json = "{}", .execute = undefined };
    const bash_t: at.AgentTool = .{ .name = "bash", .description = "", .parameters_json = "{}", .execute = undefined };
    const parent = [_]at.AgentTool{ read_t, write_t, bash_t };

    const selected = try selectTools(gpa, &parent, &[_][]const u8{ "read", "write" });
    defer gpa.free(selected);

    try testing.expectEqual(@as(usize, 2), selected.len);
    try testing.expectEqualStrings("read", selected[0].name);
    try testing.expectEqualStrings("write", selected[1].name);
}

test "registerPreset registers go-dev with correct fields" {
    const gpa = testing.allocator;
    var reg = subagent_mod.PresetRegistry.init(gpa);
    defer reg.deinit();

    try registerPreset(&reg);

    const p = reg.get("go-dev");
    try testing.expect(p != null);
    try testing.expectEqualStrings("go-dev", p.?.name);
    try testing.expectEqual(.code, p.?.default_role);
    try testing.expectEqualStrings("", p.?.default_profile);
    try testing.expect(p.?.description.len > 0);
    try testing.expect(p.?.default_system_prompt.len > 0);
}

test "buildGoDevTools returns exactly 7 tools: 6 built-in + 1 custom" {
    const gpa = testing.allocator;

    const parent = [_]at.AgentTool{
        .{ .name = "read", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "write", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "edit", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "ls", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "bash", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "grep", .description = "", .parameters_json = "{}", .execute = undefined },
        .{ .name = "find", .description = "", .parameters_json = "{}", .execute = undefined },
    };

    const tools = try buildGoDevTools(gpa, &parent);
    defer gpa.free(tools);

    try testing.expectEqual(@as(usize, 7), tools.len);
    try testing.expect(std.mem.eql(u8, "go", tools[tools.len - 1].name));

    // Helper: check if a tool name is in the list.
    const hasName = struct {
        fn check(ts: []const at.AgentTool, name: []const u8) bool {
            for (ts) |t| if (std.mem.eql(u8, t.name, name)) return true;
            return false;
        }
    }.check;

    // Built-in tools that SHOULD be present.
    try testing.expect(hasName(tools, "read"));
    try testing.expect(hasName(tools, "write"));
    try testing.expect(hasName(tools, "edit"));
    try testing.expect(hasName(tools, "ls"));
    try testing.expect(hasName(tools, "bash"));
    try testing.expect(hasName(tools, "grep"));

    // Custom Go tool that SHOULD be present.
    try testing.expect(hasName(tools, "go"));

    // Tools that should NOT be present.
    try testing.expect(!hasName(tools, "find"));
}

test "extension factory returns a properly named Extension" {
    const ext_instance = extension();
    try testing.expectEqualStrings("go-dev", ext_instance.name);
    try testing.expectEqualStrings("0.2.0", ext_instance.version);
    try testing.expect(ext_instance.init_fn != null);
}

test "init_fn registers tool and preset through Host" {
    const gpa = testing.allocator;
    var slash_reg = franky.coding.slash.Registry.init(gpa);
    defer slash_reg.deinit();
    var mgr = ext.Manager.init(gpa);
    defer mgr.deinit();

    // Set presets so the extension can register presets.
    var preset_reg = subagent_mod.PresetRegistry.init(gpa);
    defer preset_reg.deinit();
    mgr.presets = &preset_reg;

    try mgr.register(extension(), &slash_reg);

    // Check that 1 tool was registered.
    const tools = mgr.tools();
    try testing.expectEqual(@as(usize, 1), tools.len);

    // Check tool name.
    try testing.expectEqualStrings("go", tools[0].name);

    // Check that the preset was registered.
    const p = preset_reg.get("go-dev");
    try testing.expect(p != null);
    try testing.expectEqualStrings("go-dev", p.?.name);
    try testing.expectEqual(.code, p.?.default_role);
}

test "buildParametersJson includes go-dev preset" {
    const gpa = testing.allocator;
    var reg = subagent_mod.PresetRegistry.init(gpa);
    defer reg.deinit();

    try registerPreset(&reg);

    const params = try subagent_mod.buildParametersJson(gpa, &reg);
    defer gpa.free(params);

    // The JSON enum should contain the go-dev preset name.
    try testing.expect(std.mem.indexOf(u8, params, "\"go-dev\"") != null);
}

test "extension integration: full chain through Manager, Host, PresetRegistry, buildParametersJson" {
    const gpa = testing.allocator;

    // Set up the full stack: slash registry + extension manager + preset registry.
    var slash_reg = franky.coding.slash.Registry.init(gpa);
    defer slash_reg.deinit();

    var preset_reg = subagent_mod.PresetRegistry.init(gpa);
    defer preset_reg.deinit();

    var mgr = ext.Manager.init(gpa);
    defer mgr.deinit();
    mgr.presets = &preset_reg;

    // Register the extension, which triggers init_fn → host.registerTool + host.registerPreset.
    try mgr.register(extension(), &slash_reg);

    // ── verify tool registration ──
    const tools = mgr.tools();
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("go", tools[0].name);
    try testing.expect(tools[0].execute == goExecute);

    // ── verify preset registration ──
    const p = preset_reg.get("go-dev");
    try testing.expect(p != null);
    try testing.expectEqualStrings("go-dev", p.?.name);
    try testing.expectEqual(.code, p.?.default_role);
    try testing.expectEqualStrings("", p.?.default_profile);
    try testing.expect(p.?.description.len > 0);
    try testing.expect(p.?.default_system_prompt.len > 0);

    // ── verify buildParametersJson includes go-dev ──
    const params = try subagent_mod.buildParametersJson(gpa, &preset_reg);
    defer gpa.free(params);
    try testing.expect(std.mem.indexOf(u8, params, "\"go-dev\"") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"research\"") == null);

    // ── verify tool schema is well-formed JSON ──
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, tools[0].parameters_json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("required") != null);
    try testing.expect(parsed.value.object.get("properties") != null);
}

