//! go-dev extension — custom Go tools + a "go-dev" subagent preset.
//!
//! This module is a Tier-1 franky extension that registers three
//! Go-specific tools (`gofmt`, `govet`, `gotest`) and a subagent
//! preset named `"go-dev"` that bundles them alongside the standard
//! file and shell tools.
//!
//! ## Usage as a Tier-1 extension (inside franky main)
//!
//! Add the extension to the catalog in `extensions_builtin/catalog.zig`
//! and activate with `--extensions go-dev`:
//!
//! ```zig
//! const go_dev = @import("go_dev.zig");
//! // in catalog.builtins:
//! // .{ .name = "go-dev", .factory = go_dev.extension },
//! ```
//!
//! ## Usage as a standalone preset registration
//!
//! When the mode driver does NOT load extensions (print/rpc/proxy),
//! register the preset directly:
//!
//! ```zig
//! const go_dev = @import("franky-golang");
//! try go_dev.registerPreset(&preset_registry);
//! // Then preset_registry.get("go-dev") returns the preset.
//! ```
//!
//! ## Tool schemas
//!
//! | Tool | Description | Required args |
//! |------|-------------|---------------|
//! | `gofmt` | Run `gofmt -d` on a Go file | `path` (string) |
//! | `govet` | Run `go vet` on a Go package | `pkg` (string) |
//! | `gotest` | Run `go test` on a Go package | `pkg` (string), `flags` (string, optional) |

const std = @import("std");
const franky = @import("franky");

const at = franky.agent.types;
const ai = franky.ai.types;
const subagent_mod = franky.coding.tools.subagent;
const ext = franky.coding.extensions;

// ─── Tool executors ──────────────────────────────────────────────
//
// Each executor accepts the standard AgentTool.execute signature,
// shells out to the corresponding Go tool via std.process.run,
// and returns the result. Error results use structured tool_code
// values per §F.2 (gofmt_not_found, go_cmd_not_found, gofmt_failed,
// govet_failed, gotest_failed).

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

fn gofmtExecute(
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

    const GofmtArgs = struct { path: []const u8 };
    const args = try std.json.parseFromSlice(GofmtArgs, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer args.deinit();

    const path = args.value.path;

    // Reject non-.go files before calling gofmt.
    if (!std.mem.endsWith(u8, path, ".go")) {
        return toolError(allocator, "gofmt_not_a_go_file", "expected a .go file, got '{s}'", .{path});
    }

    const argv = &[_][]const u8{ "gofmt", "-d", path };

    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch |err| {
        if (err == error.FileNotFound) {
            return toolError(allocator, "gofmt_not_found", "gofmt command not found. Is Go installed and in your PATH?", .{});
        }
        return toolError(allocator, "gofmt_spawn_failed", "{s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.exited != 0) {
        return toolError(allocator, "gofmt_failed", "gofmt -d {s} exited with code {d}:\n{s}", .{ path, result.term.exited, result.stderr });
    }

    if (result.stdout.len == 0) {
        const arr = try allocator.alloc(ai.ContentBlock, 1);
        arr[0] = .{ .text = .{ .text = try allocator.dupe(u8, "File is already formatted.") } };
        return .{ .content = arr, .is_error = false };
    }

    const arr = try allocator.alloc(ai.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = try allocator.dupe(u8, result.stdout) } };
    return .{ .content = arr, .is_error = false };
}

fn govetExecute(
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

    const GovetArgs = struct {
        pkg: []const u8,
        cwd: ?[]const u8 = null,
    };
    const args = try std.json.parseFromSlice(GovetArgs, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer args.deinit();

    const pkg = args.value.pkg;
    const argv = &[_][]const u8{ "go", "vet", pkg };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (args.value.cwd) |c| .{ .path = c } else .inherit,
    }) catch |err| {
        if (err == error.FileNotFound) {
            return toolError(allocator, "go_cmd_not_found", "go command not found. Is Go installed and in your PATH?", .{});
        }
        return toolError(allocator, "govet_spawn_failed", "{s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // `go vet` can write to stderr even on success. A non-zero exit
    // code is the only reliable signal of failure.
    const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ result.stdout, result.stderr });
    defer allocator.free(output);

    if (result.term.exited != 0) {
        return toolError(allocator, "govet_failed", "go vet {s} exited with code {d}:\n{s}", .{ pkg, result.term.exited, output });
    }

    if (output.len == 0) {
        const arr = try allocator.alloc(ai.ContentBlock, 1);
        arr[0] = .{ .text = .{ .text = try allocator.dupe(u8, "`go vet` found no issues.") } };
        return .{ .content = arr, .is_error = false };
    }

    const arr = try allocator.alloc(ai.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = try allocator.dupe(u8, output) } };
    return .{ .content = arr, .is_error = false };
}

fn gotestExecute(
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

    const GotestArgs = struct {
        pkg: []const u8,
        flags: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
    };
    const args = try std.json.parseFromSlice(GotestArgs, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer args.deinit();

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);

    try argv_list.appendSlice(allocator, &[_][]const u8{ "go", "test" });
    if (args.value.flags) |f| {
        var it = std.mem.splitScalar(u8, f, ' ');
        while (it.next()) |flag| {
            if (flag.len > 0) {
                try argv_list.append(allocator, flag);
            }
        }
    }
    try argv_list.append(allocator, args.value.pkg);

    const result = std.process.run(allocator, io, .{
        .argv = argv_list.items,
        .cwd = if (args.value.cwd) |c| .{ .path = c } else .inherit,
    }) catch |err| {
        if (err == error.FileNotFound) {
            return toolError(allocator, "go_cmd_not_found", "go command not found. Is Go installed and in your PATH?", .{});
        }
        return toolError(allocator, "gotest_spawn_failed", "{s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const output = try std.fmt.allocPrint(allocator, "STDOUT:\n{s}\nSTDERR:\n{s}", .{ result.stdout, result.stderr });

    if (result.term.exited != 0) {
        defer allocator.free(output);
        return toolError(allocator, "gotest_failed", "go test exited with code {d}:\n{s}", .{ result.term.exited, output });
    }

    const arr = try allocator.alloc(ai.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = output } };
    return .{ .content = arr, .is_error = false };
}

// ─── Tool factory functions ────────────────────────────────────────

pub fn gofmtTool() at.AgentTool {
    return .{
        .name = "gofmt",
        .description = "Run gofmt -d on a Go file to show formatting diffs. Pass the file path as `path`.",
        .parameters_json =
        \\{"type":"object","required":["path"],"properties":{
        \\"path":{"type":"string","description":"Path to the Go file to format-check"}
        \\}}
        ,
        .execution_mode = .sequential,
        .execute = gofmtExecute,
    };
}

pub fn govetTool() at.AgentTool {
    return .{
        .name = "govet",
        .description = "Run go vet on a Go package to check for suspicious constructs. Pass the package path as `pkg`.",
        .parameters_json =
        \\{"type":"object","required":["pkg"],"properties":{
        \\"pkg":{"type":"string","description":"Package path (e.g. ./... or ./internal/foo)"}
        \\}}
        ,
        .execution_mode = .sequential,
        .execute = govetExecute,
    };
}

pub fn gotestTool() at.AgentTool {
    return .{
        .name = "gotest",
        .description = "Run go test on a Go package and report results. Pass `pkg` (required) and optionally `flags`.",
        .parameters_json =
        \\{"type":"object","required":["pkg"],"properties":{
        \\"pkg":{"type":"string","description":"Package path (e.g. ./...)"},
        \\"flags":{"type":"string","description":"Additional go test flags (optional, e.g. -v -race)"}
        \\}}
        ,
        .execution_mode = .sequential,
        .execute = gotestExecute,
    };
}

// ─── Preset builder ────────────────────────────────────────────────
//
// Builds the tool list for the "go-dev" subagent preset. It selects
// parent-wired tools by name (read, write, edit, ls, bash, grep) and
// appends the three custom Go tool stubs.
//
// The custom stubs are freshly constructed here rather than selected
// from parent_tools because they are extension-provided tools that
// don't exist in the parent's tool set. When the extension is loaded
// via the Tier-1 extension system, these stubs are also registered
// via `host.registerTool()` so the parent LLM can call them directly.

fn buildGoDevTools(
    allocator: std.mem.Allocator,
    parent_tools: []const at.AgentTool,
) anyerror![]at.AgentTool {
    // Step 1: select parent-wired tools by name
    const selected = try selectTools(allocator, parent_tools, &[_][]const u8{
        "read", "write", "edit", "ls", "bash", "grep",
    });
    errdefer allocator.free(selected);

    // Step 2: append the three custom Go tool stubs
    const custom = [_]at.AgentTool{
        gofmtTool(),
        govetTool(),
        gotestTool(),
    };

    const total = try allocator.alloc(at.AgentTool, selected.len + custom.len);
    @memcpy(total[0..selected.len], selected);
    @memcpy(total[selected.len..], &custom);
    allocator.free(selected);
    return total;
}

// ─── registerPreset helper (standalone) ────────────────────────────
//
// Registers the "go-dev" preset into any PresetRegistry without going
// through the extension system. This is useful for mode drivers that
// don't load extensions (print, rpc, proxy) but still want the
// go-dev preset available.

pub fn registerPreset(registry: *subagent_mod.PresetRegistry) !void {
    try registry.register(.{
        .name = "go-dev",
        .description = "Go development: edit, format, vet, and test Go code.",
        .default_profile = "",
        .default_role = .code,
        .default_system_prompt =
        \\You are a Go development sub-agent. Your job is to help develop,
        \\review, and maintain Go code.
        \\
        \\You have the usual file tools (read, write, edit, ls, grep, bash)
        \\plus Go-specific tools (gofmt, govet, gotest).
        \\
        \\Workflow:
        \\  1. Read the relevant files first to understand the codebase.
        \\  2. Make focused edits. Use edit over write for existing files.
        \\  3. Run gofmt on every Go file you create or modify.
        \\  4. Run go vet on affected packages after making changes.
        \\  5. Run go test to verify correctness.
        \\  6. Report what you did and what the tool output says.
        ,
        .build_tools = buildGoDevTools,
    });
}

// ─── Extension entry point (Tier-1) ────────────────────────────────
//
// When loaded via `--extensions go-dev`, init_fn:
//   1. Registers the three Go tool stubs with the host so the
//      parent LLM can call them directly.
//   2. Registers the "go-dev" preset via host.registerPreset() so
//      the subagent tool can spawn a Go-focused sub-agent.

pub fn extension() ext.Extension {
    return .{
        .name = "go-dev",
        .version = "0.1.0",
        .init_fn = init,
    };
}

fn init(_: *ext.Extension, host: *ext.Host) ext.ExtError!void {
    // Register custom tools so the parent LLM sees them.
    try host.registerTool(gofmtTool());
    try host.registerTool(govetTool());
    try host.registerTool(gotestTool());

    // Register the "go-dev" preset.
    // host.presets is set by the mode driver (via Manager.presets).
    // When null we silently no-op so the extension loads in modes
    // that haven't wired the preset hook yet (print, rpc, proxy),
    // albeit without registering the preset.
    if (host.presets) |registry| try registerPreset(registry);
}

// ─── Internal helpers ──────────────────────────────────────────────

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

// ─── Tool-error helper tests ─────────────────────────────────────

test "toolError: renders [code] msg + sets tool_code + is_error=true" {
    const gpa = testing.allocator;
    var res = try toolError(gpa, "gofmt_not_found", "{s} {s}", .{ "hello", "world" });
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expect(res.tool_code != null);
    try testing.expectEqualStrings("gofmt_not_found", res.tool_code.?);
    try testing.expectEqual(@as(usize, 1), res.content.len);
    try testing.expectEqualStrings(
        "[gofmt_not_found] hello world",
        res.content[0].text.text,
    );
}

test "toolError: empty format args" {
    const gpa = testing.allocator;
    var res = try toolError(gpa, "go_cmd_not_found", "go not in PATH", .{});
    defer res.deinit(gpa);
    try testing.expect(res.is_error);
    try testing.expectEqualStrings("go_cmd_not_found", res.tool_code.?);
    try testing.expectEqualStrings(
        "[go_cmd_not_found] go not in PATH",
        res.content[0].text.text,
    );
}

// ─── Execute function tests (require go + gofmt in PATH) ─────────

test "gofmtExecute: formats badly indented .go file" {
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
    try dir.writeFile(io, .{ .sub_path = "test.go", .data = badly_formatted });

    // Build the args JSON for gofmtExecute.
    const abs_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/test.go", .{tmp_dir.sub_path});
    defer gpa.free(abs_path);

    const args_json = try std.fmt.allocPrint(gpa, "{{ \"path\": \"{s}\" }}", .{abs_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = gofmtTool();
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

    // gofmt -d on a badly formatted file returns a diff.
    try testing.expect(!result.is_error);
    try testing.expect(result.content.len > 0);
    try testing.expect(result.content[0].text.text.len > 0);
    // The diff should mention test.go.
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "test.go") != null);
}

test "gofmtExecute: already formatted file returns no-diff message" {
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

    const args_json = try std.fmt.allocPrint(gpa, "{{ \"path\": \"{s}\" }}", .{abs_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = gofmtTool();
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

test "gofmtExecute: non-.go path returns tool error with code gofmt_not_a_go_file" {
    const gpa = testing.allocator;
    const args_json = "{\"path\": \"/tmp/foo.txt\"}";
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cancel = franky.ai.stream.Cancel{};

    const tool = gofmtTool();
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
    try testing.expectEqualStrings("gofmt_not_a_go_file", result.tool_code.?);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, ".go") != null);
}

test "gofmtExecute: non-existent path returns spawn error" {
    const gpa = testing.allocator;
    const args_json = "{\"path\": \"/tmp/nonexistent_dir_12345/test.go\"}";
    var threaded = std.Io.Threaded.init(gpa, .{ .argv0 = .empty, .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var cancel = franky.ai.stream.Cancel{};

    const tool = gofmtTool();
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

test "govetExecute: passes on well-formed package" {
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
    const args_json = try std.fmt.allocPrint(gpa, "{{ \"pkg\": \".\", \"cwd\": \"{s}\" }}", .{cwd_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = govetTool();
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

test "gotestExecute: passes on passing test" {
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
    const args_json = try std.fmt.allocPrint(gpa, "{{ \"pkg\": \".\", \"cwd\": \"{s}\" }}", .{cwd_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = gotestTool();
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

test "gotestExecute: failing test returns error with tool_code gotest_failed" {
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
    const args_json = try std.fmt.allocPrint(gpa, "{{ \"pkg\": \".\", \"cwd\": \"{s}\" }}", .{cwd_path});
    defer gpa.free(args_json);

    var cancel = franky.ai.stream.Cancel{};

    const tool = gotestTool();
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
    try testing.expectEqualStrings("gotest_failed", result.tool_code.?);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "FAIL") != null);
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "gofmtTool returns a properly named AgentTool" {
    const t = gofmtTool();
    try testing.expectEqualStrings("gofmt", t.name);
    try testing.expect(t.description.len > 0);
    try testing.expect(t.parameters_json.len > 0);
    try testing.expect(t.execute == gofmtExecute);
}

test "govetTool returns a properly named AgentTool" {
    const t = govetTool();
    try testing.expectEqualStrings("govet", t.name);
    try testing.expect(t.description.len > 0);
    try testing.expect(t.parameters_json.len > 0);
    try testing.expect(t.execute == govetExecute);
}

test "gotestTool returns a properly named AgentTool" {
    const t = gotestTool();
    try testing.expectEqualStrings("gotest", t.name);
    try testing.expect(t.description.len > 0);
    try testing.expect(t.parameters_json.len > 0);
    try testing.expect(t.execute == gotestExecute);
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

test "buildGoDevTools returns exactly 9 tools: 6 built-in + 3 custom" {
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

    try testing.expectEqual(@as(usize, 9), tools.len);

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

    // Custom Go tools that SHOULD be present.
    try testing.expect(hasName(tools, "gofmt"));
    try testing.expect(hasName(tools, "govet"));
    try testing.expect(hasName(tools, "gotest"));

    // Tools that should NOT be present.
    try testing.expect(!hasName(tools, "find"));
}

test "extension factory returns a properly named Extension" {
    const ext_instance = extension();
    try testing.expectEqualStrings("go-dev", ext_instance.name);
    try testing.expectEqualStrings("0.1.0", ext_instance.version);
    try testing.expect(ext_instance.init_fn != null);
}

test "init_fn registers tools and preset through Host" {
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

    // Check that 3 tools were registered.
    const tools = mgr.tools();
    try testing.expectEqual(@as(usize, 3), tools.len);

    // Check each tool name.
    inline for (.{ "gofmt", "govet", "gotest" }) |name| {
        var found = false;
        for (tools) |t| {
            if (std.mem.eql(u8, t.name, name)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    // Check that the preset was registered.
    const p = preset_reg.get("go-dev");
    try testing.expect(p != null);
    try testing.expectEqualStrings("go-dev", p.?.name);
    try testing.expectEqual(.code, p.?.default_role);
}
