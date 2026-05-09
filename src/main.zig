//! franky-go — standalone binary with go-dev extension + skills pre-loaded.
//!
//! This binary replicates the agent-loop setup from franky's print mode
//! but bakes in the go-dev tool + preset and loads skills from the local
//! skills/ directory. It follows the "standalone preset registration" path
//! from spec §6.2: no extension-manager wiring, just direct preset +
//! tool registration.
//!
//! Usage:
//!   zig build run -- "Add a health check handler to main.go"
//!   zig build run -- --provider faux "hello"
//!   zig build run -- --model sonnet "run go test ./..."
//!
//! All standard franky flags work: --provider, --model, --profile,
//! --log-level, --no-session, --role, --system-prompt, etc.

const std = @import("std");
const franky = @import("franky");
const franky_go = @import("franky-golang");

const ai = franky.ai;
const agent = franky.agent;
const at = agent.types;
const tools_mod = franky.coding.tools;
const cli_mod = franky.coding.cli;
const role_mod = franky.coding.role;
const permissions_mod = franky.coding.permissions;
const settings_mod = franky.coding.settings;
const profiles_mod = franky.coding.profiles;
const skills_mod = franky.coding.skills;
const session_mod = franky.coding.session;
const branching_mod = franky.coding.branching;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Collect argv into []const []const u8 for CLI parsing.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    while (it.next()) |raw| {
        try args_list.append(gpa, try gpa.dupe(u8, raw));
    }
    const argv = args_list.items;

    // ── CLI parse ──────────────────────────────────────────────────
    var cfg = cli_mod.parse(gpa, argv) catch |e| switch (e) {
        error.MissingValue => return exitWithMessage(io, "missing value for flag; see --help\n", 2),
        error.UnknownMode => return exitWithMessage(io, "unknown --mode value; use print\n", 2),
        error.UnknownThinkingLevel => return exitWithMessage(io, "unknown --thinking value; use off|minimal|low|medium|high|xhigh\n", 2),
        else => |err| return err,
    };
    defer cfg.deinit();

    // ── Profile ────────────────────────────────────────────────────
    if (cfg.profile) |profile_name| {
        profiles_mod.applyProfile(&cfg, io, init.environ_map, profile_name) catch |e| switch (e) {
            error.ProfileNotFound => {
                const msg = try std.fmt.allocPrint(gpa, "profile '{s}' not found in any settings.json layer\n", .{profile_name});
                defer gpa.free(msg);
                return exitWithMessage(io, msg, 2);
            },
            error.MalformedProfile => return exitWithMessage(io, "malformed profile in settings.json\n", 2),
            error.UnknownMode => return exitWithMessage(io, "profile contains unknown mode\n", 2),
            error.UnknownThinkingLevel => return exitWithMessage(io, "profile contains unknown thinking level\n", 2),
            else => |err| return err,
        };
    }

    if (cfg.show_help) {
        return writeOut(io, cli_mod.usage_text);
    }
    if (cfg.show_version) {
        const msg = try std.fmt.allocPrint(gpa, "franky-go 0.4.0 (franky {s})\n", .{franky.version});
        defer gpa.free(msg);
        return writeOut(io, msg);
    }

    // ── Log init ───────────────────────────────────────────────────
    const log_level = resolveLogLevel(&cfg, init.minimal.environ);
    ai.log.init(io, log_level);
    defer ai.log.deinit();

    // ── Mode dispatch ──────────────────────────────────────────────
    // Interactive mode delegates to the upstream franky interactive runner.
    // This means go-dev is NOT available in interactive mode yet — that's
    // a v1.0.0 follow-up when the catalog integration is complete.
    if (cfg.mode == .interactive) {
        return franky.coding.modes.interactive.run(gpa, io, init.minimal.environ, init.environ_map, &cfg);
    }

    // ── Agent loop setup (print mode, with go-dev pre-loaded) ──────
    try runFrankyGo(gpa, io, &cfg, init.minimal.environ, init.environ_map);
}

fn runFrankyGo(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *cli_mod.Config,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
) !void {
    // ── Provider selection ────────────────────────────────────────
    const provider_info = try resolveProviderIo(allocator, io, environ, cfg);

    {
        const auth_scheme: []const u8 = if (provider_info.auth_token != null)
            "bearer"
        else if (provider_info.api_key != null)
            "x-api-key"
        else
            "none";
        ai.log.log(.info, "cfg", "resolved", "provider={s} model={s} auth={s} thinking={s}", .{
            provider_info.provider_name,
            provider_info.model_id,
            auth_scheme,
            cfg.thinking.toString(),
        });
    }

    // ── Registry setup ────────────────────────────────────────────
    var reg = ai.registry.Registry.init(allocator);
    defer reg.deinit();

    var faux = ai.providers.faux.FauxProvider.init(allocator);
    defer faux.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });
    try reg.register(.{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .stream_fn = ai.providers.anthropic.streamFn,
    });
    try reg.register(.{
        .api = "openai-chat-completions",
        .provider = "openai",
        .stream_fn = ai.providers.openai_chat.streamFn,
    });
    try reg.register(.{
        .api = "openai-compatible-gateway",
        .provider = "gateway",
        .stream_fn = ai.providers.openai_gateway.streamFn,
    });
    try reg.register(.{
        .api = "google-gemini",
        .provider = "google-gemini",
        .stream_fn = ai.providers.google_gemini.streamFn,
    });

    // Faux reply for self-contained demo without API key.
    const faux_reply: ?[]u8 = if (std.mem.eql(u8, provider_info.provider_name, "faux"))
        try std.fmt.allocPrint(allocator, "you said: {s}", .{cfg.prompt})
    else
        null;
    defer if (faux_reply) |r| allocator.free(r);

    var faux_events: [1]ai.providers.faux.Event = undefined;
    if (faux_reply) |r| {
        faux_events[0] = .{ .text = .{ .text = r, .chunk_size = 8 } };
        try faux.push(.{ .events = faux_events[0..] });
    }

    // ── Workspace + env policy ─────────────────────────────────────
    const workspace_root: ?[]const u8 = environ.getPosix("PWD");
    var workspace_state: ?tools_mod.workspace.Workspace = if (workspace_root) |root|
        tools_mod.workspace.Workspace{ .root = root, .host_env = environ_map }
    else
        null;

    var bash_state = tools_mod.bash.SessionBashState.init(allocator);
    defer bash_state.deinit();
    var read_ctx = tools_mod.read.ReadCtx{
        .workspace = if (workspace_state) |*ws| ws else null,
    };
    {
        var settings = loadSettingsForOverlay(allocator, io, environ);
        applyBashSettingsOverlay(&bash_state, &settings);
        applyReadSettingsOverlay(&read_ctx, &settings);
    }

    var bash_ctx = tools_mod.bash.BashCtx{
        .state = &bash_state,
        .workspace = if (workspace_state) |*ws| ws else null,
    };

    // ── Core tools ─────────────────────────────────────────────────
    const all_tools = if (workspace_state) |*ws| [_]at.AgentTool{
        tools_mod.read.toolWithCtx(&read_ctx),
        tools_mod.write.toolWithWorkspace(ws),
        tools_mod.edit.toolWithWorkspace(ws),
        tools_mod.bash.toolWithStateAndWorkspace(&bash_ctx),
        tools_mod.ls.toolWithWorkspace(ws),
        tools_mod.find.toolWithWorkspace(ws),
        tools_mod.grep.toolWithWorkspace(ws),
    } else [_]at.AgentTool{
        tools_mod.read.tool(),
        tools_mod.write.tool(),
        tools_mod.edit.tool(),
        tools_mod.bash.toolWithState(&bash_state),
        tools_mod.ls.tool(),
        tools_mod.find.tool(),
        tools_mod.grep.tool(),
    };

    // ── Role gate ──────────────────────────────────────────────────
    const active_role = if (cfg.role) |s|
        role_mod.Role.fromString(s) catch return exitWithMessage(
            io,
            "unknown --role; pick one of read, plan, code, full\n",
            2,
        )
    else
        role_mod.Role.plan;
    var role_gate = role_mod.RoleGate.init(active_role);
    const filtered_tools = try role_mod.filterTools(allocator, &all_tools, role_gate.set);
    defer allocator.free(filtered_tools);

    // ── Permission gate ────────────────────────────────────────────
    var permission_store = permissions_mod.Store.init(allocator);
    defer permission_store.deinit();
    var prompts_enabled: bool = cfg.prompts;
    {
        var settings = loadSettingsForOverlay(allocator, io, environ);
        try applyPermissionsSettingsOverlay(&permission_store, &settings);
        prompts_enabled = resolvePromptsDefault(cfg, &settings);
    }
    if (cfg.yes) permission_store.yes_to_all = true;
    if (cfg.allow_tools_csv) |s| try permission_store.addAllowList(s);
    if (cfg.deny_tools_csv) |s| try permission_store.addDenyList(s);
    if (cfg.ask_tools_csv) |s| try permission_store.addAskList(s);
    try permissions_mod.maybeAttachPersistence(
        &permission_store,
        cfg.remember_permissions,
        cfg.arena.allocator(),
        io,
        environ_map,
    );
    var session_gates: permissions_mod.SessionGates = .{
        .role = &role_gate,
        .permissions = if (prompts_enabled) &permission_store else null,
    };

    // ── Preset registry — built-in + go-dev ─────────────────────────
    var preset_registry = tools_mod.subagent.PresetRegistry.init(allocator);
    defer preset_registry.deinit();
    try tools_mod.subagent.registerBuiltinPresets(&preset_registry);
    try franky_go.registerPreset(&preset_registry); // ← go-dev preset

    const subagent_params_json = try tools_mod.subagent.buildParametersJson(
        allocator, &preset_registry);
    defer allocator.free(subagent_params_json);

    var subagent_ctx = tools_mod.subagent.Ctx{
        .registry = &reg,
        .environ = environ,
        .environ_map = environ_map,
        .parent_tools = filtered_tools,
        .parent_role = active_role,
        .parent_profile = cfg.profile orelse "",
        .presets = &preset_registry,
        .parameters_json_owned = subagent_params_json,
        .permission_store = if (prompts_enabled) &permission_store else null,
        .permission_prompter_slot = null,
        .parent_session_dir = null,
    };

    // ── Guardrails ─────────────────────────────────────────────────
    var guardrail_state = try agent.guardrails.GuardrailState.init(
        allocator,
        .{ .workspace_dir = workspace_root orelse "." },
        io,
    );
    defer guardrail_state.deinit();

    // ── Final tool list: filtered + subagent + listPresets + finishTask + go ─
    // Note: subagent tool, listPresets tool, and finishTask tool are
    // ALWAYS included (they're infra, not role-gated). The go tool is
    // appended as a custom tool available to the parent LLM.
    const final_tools = blk: {
        const slice = try allocator.alloc(at.AgentTool, filtered_tools.len + 4);
        @memcpy(slice[0..filtered_tools.len], filtered_tools);
        slice[filtered_tools.len] = tools_mod.subagent.toolWithCtx(&subagent_ctx);
        slice[filtered_tools.len + 1] = tools_mod.subagent.listPresetsToolWithCtx(&preset_registry);
        slice[filtered_tools.len + 2] = guardrail_state.finishTaskTool();
        slice[filtered_tools.len + 3] = franky_go.goTool(); // ← go tool for parent LLM
        break :blk slice;
    };
    defer allocator.free(final_tools);

    // ── Sandbox warning ────────────────────────────────────────────
    {
        const sandbox_active = role_mod.detectSandbox(environ);
        var stderr_buf: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
        stderr.interface.print(
            "franky-go · role={s} · sandbox={s}\n",
            .{ active_role.toString(), if (sandbox_active) "yes" else "no" },
        ) catch {};
        if (!sandbox_active and (active_role == .code or active_role == .full)) {
            stderr.interface.print(
                "⚠ Running outside a sandbox with role={s}. Tool calls execute on the host filesystem.\n" ++
                "  Consider:  zerobox -- franky-go --role {s} ...   (or --role plan to disable bash)\n",
                .{ active_role.toString(), active_role.toString() },
            ) catch {};
        }
        stderr.interface.flush() catch {};
    }

    // ── Session / transcript ───────────────────────────────────────
    var session_state = try SessionState.init(allocator, io, environ, cfg);
    defer session_state.deinit(allocator);

    // ── System prompt with skills ──────────────────────────────────
    const system_prompt = try buildSystemPromptIo(allocator, io, environ, cfg);
    defer allocator.free(system_prompt);

    const model: ai.types.Model = .{
        .id = provider_info.model_id,
        .provider = provider_info.provider_name,
        .api = provider_info.api_tag,
        .context_window = provider_info.context_window,
        .max_output = provider_info.max_output,
        .capabilities = provider_info.capabilities,
    };

    // ── Agent loop ─────────────────────────────────────────────────
    var cancel = ai.stream.Cancel{};
    var ch = try agent.loop.AgentChannel.initWithDrop(
        allocator,
        65536,
        at.AgentEvent.deinit,
        allocator,
    );
    defer ch.deinit();

    var loop_cfg: agent.loop.Config = .{
        .model = model,
        .system_prompt = system_prompt,
        .tools = final_tools,
        .registry = &reg,
        .cancel = &cancel,
        .guardrails = &guardrail_state,
        .hook_userdata = @ptrCast(&session_gates),
        .role_denied = permissions_mod.SessionGates.roleDenied,
        .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
        .text_tool_call_fallback = cfg.text_tool_call_fallback,
        .reducer_dump_dir = null,
        .stream_options = .{
            .api_key = provider_info.api_key,
            .auth_token = provider_info.auth_token,
            .base_url = provider_info.base_url,
            .environ_map = environ_map,
            .thinking = cfg.thinking,
            .timeouts = resolveTimeoutsFromMap(cfg, environ_map),
            .retry_policy = resolveRetryPolicyFromMap(cfg, null),
            .http_trace_dir = resolveHttpTraceDirFromMap(cfg, environ_map),
        },
    };
    if (resolveMaxTurnsFromMap(cfg, environ_map)) |v| loop_cfg.max_turns = v;

    const WorkerArgs = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *agent.loop.Transcript,
        config: agent.loop.Config,
        ch: *agent.loop.AgentChannel,
    };
    const worker_args: WorkerArgs = .{
        .allocator = allocator,
        .io = io,
        .transcript = &session_state.transcript,
        .config = loop_cfg,
        .ch = &ch,
    };
    const worker = try std.Thread.spawn(.{}, workerMain, .{worker_args});
    defer worker.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    var saw_error = false;
    while (ch.next(io)) |ev| {
        switch (ev) {
            .message_update => |u| switch (u) {
                .text => |t| stdout.interface.writeAll(t.delta) catch {},
                else => {},
            },
            .tool_execution_start => |s| {
                ai.log.log(.info, "tool", "start", "id={s} name={s}", .{ s.call_id, s.name });
            },
            .tool_execution_end => |e| {
                ai.log.log(.info, "tool", "end", "id={s} is_error={}", .{ e.call_id, e.result.is_error });
            },
            .agent_error => |details| {
                saw_error = true;
                ai.log.log(.err, "agent", "error", "code={s} message={s}", .{ details.code.toString(), details.message });
            },
            .turn_end => {
                stdout.interface.writeAll("\n") catch {};
                stdout.interface.flush() catch {};
            },
            else => {},
        }
        ev.deinit(allocator);
    }
    stdout.interface.flush() catch {};

    // ── Persist session ───────────────────────────────────────────
    if (!cfg.no_session) {
        session_state.persist(allocator, io, provider_info, cfg) catch |err| {
            ai.log.log(.err, "session", "persist_failed", "error={s}", .{@errorName(err)});
        };
    }

    if (saw_error) std.process.exit(1);
}

fn workerMain(args: anytype) void {
    agent.loop.agentLoop(args.allocator, args.io, args.transcript, args.config, args.ch);
}

// ─── Session state (local copy of print.zig's private SessionState) ──

const SessionState = struct {
    arena: std.heap.ArenaAllocator,
    session_id: []const u8,
    parent_dir: ?[]const u8,
    transcript: agent.loop.Transcript,
    created_at_ms: i64,
    tree: branching_mod.Tree,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        cfg: *cli_mod.Config,
    ) !SessionState {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const a = arena.allocator();

        const parent_dir: ?[]const u8 = if (cfg.no_session) null else blk: {
            if (cfg.session_dir) |d| break :blk try a.dupe(u8, d);
            const franky_home: ?[]const u8 = environ.getPosix("FRANKY_HOME");
            if (franky_home) |h| {
                break :blk try std.fs.path.join(a, &.{ h, "sessions" });
            }
            const home: ?[]const u8 = environ.getPosix("HOME");
            if (home) |h| {
                break :blk try std.fs.path.join(a, &.{ h, ".franky", "sessions" });
            }
            break :blk try a.dupe(u8, "./.franky-sessions");
        };

        if (cfg.resume_id) |sid| {
            if (parent_dir == null) return error.ResumeFailed;
            const loaded = session_mod.load(allocator, io, parent_dir.?, sid) catch |err| {
                arena.deinit();
                return err;
            };
            var transcript = loaded.transcript;
            const created_ms = loaded.header.created_at_ms;
            const owned_id = try a.dupe(u8, sid);
            session_mod.freeSessionHeader(allocator, loaded.header);
            const session_dir = try std.fs.path.join(a, &.{ parent_dir.?, owned_id });
            var tree = branching_mod.loadTree(allocator, io, session_dir) catch try branching_mod.Tree.init(allocator);

            if (cfg.checkout_branch) |name| {
                tree.switchTo(name) catch {};
                if (session_mod.readBranchTranscript(allocator, io, session_dir, name)) |snap| {
                    transcript.deinit();
                    transcript = snap;
                } else |_| {
                    ai.log.log(.warn, "session", "checkout_snapshot_missing", "branch={s}", .{name});
                }
            }

            if (cfg.fork_branch) |name| {
                const msg_count: u32 = @intCast(transcript.messages.items.len);
                tree.fork(name, tree.active, msg_count) catch {};
                tree.switchTo(name) catch {};
                session_mod.writeBranchTranscript(allocator, io, session_dir, &transcript, name) catch {};
            }
            return .{
                .arena = arena,
                .session_id = owned_id,
                .parent_dir = parent_dir,
                .transcript = transcript,
                .created_at_ms = created_ms,
                .tree = tree,
            };
        }

        const owned_id = if (cfg.session_id) |sid|
            try a.dupe(u8, sid)
        else blk: {
            var prng = std.Random.DefaultPrng.init(@bitCast(ai.stream.nowMillis()));
            const now: u64 = @intCast(ai.stream.nowMillis());
            const u = session_mod.newUlid(now, prng.random());
            break :blk try a.dupe(u8, u.asSlice());
        };

        var tree = try branching_mod.Tree.init(allocator);
        if (cfg.fork_branch) |name| {
            tree.fork(name, tree.active, 0) catch {};
            tree.switchTo(name) catch {};
        }

        return .{
            .arena = arena,
            .session_id = owned_id,
            .parent_dir = parent_dir,
            .transcript = agent.loop.Transcript.init(allocator),
            .created_at_ms = ai.stream.nowMillis(),
            .tree = tree,
        };
    }

    fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.transcript.deinit();
        self.tree.deinit();
        self.arena.deinit();
    }

    fn persist(
        self: *SessionState,
        allocator: std.mem.Allocator,
        io: std.Io,
        info: anytype,
        cfg: *cli_mod.Config,
    ) !void {
        const parent = self.parent_dir orelse return;

        const title = if (self.transcript.messages.items.len > 0 and
            self.transcript.messages.items[0].role == .user and
            self.transcript.messages.items[0].content.len > 0)
        blk: {
            const first = self.transcript.messages.items[0].content[0];
            switch (first) {
                .text => |t| {
                    const max_len = 64;
                    const take = @min(t.text.len, max_len);
                    break :blk t.text[0..take];
                },
                else => break :blk "franky-go session",
            }
        } else "franky-go session";

        const header = session_mod.SessionHeader{
            .id = self.session_id,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = ai.stream.nowMillis(),
            .title = title,
            .provider = info.provider_name,
            .model = info.model_id,
            .api = info.api_tag,
            .thinking_level = cfg.thinking.toString(),
        };

        const session_dir = try std.fs.path.join(allocator, &.{ parent, self.session_id });
        defer allocator.free(session_dir);

        // Ensure session directory exists.
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, session_dir) catch {};

        try session_mod.writeSessionHeader(allocator, io, session_dir, header);
        try session_mod.writeTranscript(allocator, io, session_dir, &self.transcript, self.tree.active);
        try branching_mod.saveTree(allocator, io, session_dir, &self.tree);
        try session_mod.writeBranchTranscript(allocator, io, session_dir, &self.transcript, self.tree.active);
    }
};

// ─── Re-exported helpers from print.zig ──────────────────────────────

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const faux_ptr: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux_ptr.runSync(ctx.io, ctx.context, ctx.out);
}

fn writeOut(io: std.Io, s: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(s) catch {};
    w.interface.flush() catch {};
}

fn exitWithMessage(io: std.Io, msg: []const u8, code: u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
    std.process.exit(code);
}

// ─── Log level resolution ────────────────────────────────────────────

fn extractGlobalLevel(s: []const u8) ?ai.log.Level {
    var it = std.mem.splitScalar(u8, s, ',');
    var result: ?ai.log.Level = null;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |_| continue;
        if (ai.log.Level.fromString(trimmed)) |l| result = l;
    }
    return result;
}

fn resolveLogLevel(cfg: *const cli_mod.Config, environ: std.process.Environ) ai.log.Level {
    if (cfg.log_level) |s| {
        if (extractGlobalLevel(s)) |l| return l;
        if (ai.log.Level.fromString(s)) |l| return l;
    }
    if (environ.getPosix("FRANKY_LOG")) |s| {
        if (extractGlobalLevel(s)) |l| return l;
        if (ai.log.Level.fromString(s)) |l| return l;
    }
    if (environ.getPosix("FRANKY_DEBUG")) |v| {
        if (v.len > 0 and v[0] != '0') return .debug;
    }
    return .warn;
}

// ─── Settings overlay helpers (thin re-exports from print mode) ──────

const SettingsOverlay = struct {
    bash_timeout_ms: ?u64 = null,
    read_max_bytes: ?usize = null,
};

fn loadSettingsForOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) SettingsOverlay {
    _ = allocator;
    _ = io;
    _ = environ;
    return SettingsOverlay{};
}

fn applyBashSettingsOverlay(state: *tools_mod.bash.SessionBashState, settings: *const SettingsOverlay) void {
    if (settings.bash_timeout_ms) |t| state.default_timeout_ms_override = t;
}

fn applyReadSettingsOverlay(ctx: *tools_mod.read.ReadCtx, settings: *const SettingsOverlay) void {
    if (settings.read_max_bytes) |m| ctx.max_bytes_without_limit_override = m;
}

fn applyPermissionsSettingsOverlay(store: *permissions_mod.Store, settings: *const SettingsOverlay) !void {
    _ = store;
    _ = settings;
}

fn resolvePromptsDefault(cfg: *const cli_mod.Config, settings: *const SettingsOverlay) bool {
    _ = settings;
    return cfg.prompts;
}

// ─── Provider + timeout helpers ──────────────────────────────────────

const ProviderInfo = struct {
    provider_name: []const u8,
    model_id: []const u8,
    api_tag: []const u8,
    api_key: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    context_window: u32 = 1_000_000,
    max_output: u32 = 8192,
    capabilities: ai.types.Capabilities = .{},
};

fn resolveProviderIo(
    allocator: std.mem.Allocator,
    _: std.Io,
    environ: std.process.Environ,
    cfg: *cli_mod.Config,
) !ProviderInfo {
    const provider: []const u8 = if (cfg.provider) |p| p else blk: {
        // Auto-detect: if ANTHROPIC_API_KEY is set, default to anthropic.
        if (environ.getPosix("ANTHROPIC_API_KEY") != null) break :blk "anthropic";
        break :blk "faux";
    };

    _ = allocator;

    const model_id = if (cfg.model) |m| m else defaultModelFor(provider);
    const api_tag = apiTagFor(provider);

    return .{
        .provider_name = provider,
        .model_id = model_id,
        .api_tag = api_tag,
        .api_key = cfg.api_key orelse environ.getPosix("ANTHROPIC_API_KEY"),
        .auth_token = cfg.auth_token orelse environ.getPosix("ANTHROPIC_AUTH_TOKEN") orelse environ.getPosix("CLAUDE_CODE_OAUTH_TOKEN"),
        .base_url = cfg.base_url,
    };
}

fn defaultModelFor(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "anthropic")) return "claude-sonnet-4-6";
    if (std.mem.eql(u8, provider, "openai")) return "gpt-4o";
    if (std.mem.eql(u8, provider, "gateway")) return "gpt-4o";
    if (std.mem.eql(u8, provider, "google-gemini")) return "gemini-2.0-flash";
    return "faux-model";
}

fn apiTagFor(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "anthropic")) return "anthropic-messages";
    if (std.mem.eql(u8, provider, "openai")) return "openai-chat-completions";
    if (std.mem.eql(u8, provider, "gateway")) return "openai-compatible-gateway";
    if (std.mem.eql(u8, provider, "google-gemini")) return "google-gemini";
    return "faux";
}

fn resolveTimeoutsFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *std.process.Environ.Map,
) ai.registry.Timeouts {
    _ = cfg;
    _ = environ_map;
    return .{};
}

fn resolveRetryPolicyFromMap(
    cfg: *const cli_mod.Config,
    _: ?*const anyopaque,
) ai.retry.Policy {
    _ = cfg;
    return .{};
}

fn resolveHttpTraceDirFromMap(
    cfg: *const cli_mod.Config,
    environ_map: *std.process.Environ.Map,
) ?[]const u8 {
    _ = cfg;
    if (environ_map.get("FRANKY_HTTP_TRACE_DIR")) |d| return d;
    return null;
}

fn resolveMaxTurnsFromMap(cfg: *const cli_mod.Config, environ_map: *std.process.Environ.Map) ?u32 {
    if (cfg.max_turns) |v| return v;
    if (environ_map.get("FRANKY_MAX_TURNS")) |s| {
        return std.fmt.parseUnsigned(u32, s, 10) catch null;
    }
    return null;
}

// ─── System prompt builder (minimal, with skills support) ────────────

const default_system_prompt =
    \\You are franky — a Go-capable AI coding agent.
    \\
    \\You have standard file tools (read, write, edit, ls, find, grep, bash)
    \\plus a custom "go" tool that dispatches fmt, vet, build, and test.
    \\
    \\The "subagent" tool can spawn a dedicated Go development sub-agent
    \\via preset="go-dev" for focused Go tasks.
    \\
    \\Workflow:
    \\  1. Read the relevant files first to understand the codebase.
    \\  2. Make focused edits. Use edit over write for existing files.
    \\  3. Run `go fmt` on every .go file you create or modify.
    \\  4. Run `go vet` on affected packages after changes.
    \\  5. Run `go build` to check compilation.
    \\  6. Run `go test` to verify correctness.
    \\  7. Report what you did and what the tool output says.
    ;

fn buildSystemPromptIo(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    environ: std.process.Environ,
    cfg: *const cli_mod.Config,
) ![]u8 {
    if (cfg.system_prompt) |s| return try allocator.dupe(u8, s);

    // Base: disk template or default.
    var base: []u8 = undefined;
    var loaded_from_disk = false;

    // Try <workspace>/skills/system.md or $FRANKY_HOME/system.md.
    if (io) |ioref| {
        const pwd = environ.getPosix("PWD");
        if (pwd) |p| {
            const path = try std.fs.path.join(allocator, &.{ p, "skills", "system.md" });
            defer allocator.free(path);
            if (readWholeFileOpt(allocator, ioref, path)) |bytes| {
                base = bytes;
                loaded_from_disk = true;
            }
        }
        if (!loaded_from_disk) {
            const franky_home = environ.getPosix("FRANKY_HOME");
            const home = environ.getPosix("HOME");
            if (franky_home) |h| {
                const path = try std.fs.path.join(allocator, &.{ h, "system.md" });
                defer allocator.free(path);
                if (readWholeFileOpt(allocator, ioref, path)) |bytes| {
                    base = bytes;
                    loaded_from_disk = true;
                }
            }
            if (!loaded_from_disk) {
                if (home) |h| {
                    const path = try std.fs.path.join(allocator, &.{ h, ".franky", "system.md" });
                    defer allocator.free(path);
                    if (readWholeFileOpt(allocator, ioref, path)) |bytes| {
                        base = bytes;
                        loaded_from_disk = true;
                    }
                }
            }
        }
    }

    if (!loaded_from_disk) {
        base = try allocator.dupe(u8, default_system_prompt);
    }
    // Always free base — it's always heap-allocated in every path.
    defer allocator.free(base);

    // Inject PWD hint.
    if (environ.getPosix("PWD")) |pwd| {
        const trimmed = std.mem.trimEnd(u8, base, &std.ascii.whitespace);
        const inj = try std.fmt.allocPrint(allocator, "Current folder: {s}\n\n{s}", .{ pwd, trimmed });
        allocator.free(base);
        base = inj;
    }

    // Append skills section.
    var with_skills: []u8 = base;
    var skills_owned = false;
    if (io) |ioref| skills_block: {
        const pwd = environ.getPosix("PWD");

        var workspace_skills_root: ?[]u8 = null;
        defer if (workspace_skills_root) |b| allocator.free(b);
        if (pwd) |p| {
            workspace_skills_root = std.fs.path.join(allocator, &.{ p, "skills" }) catch null;
        }

        var user_skills_root: ?[]u8 = null;
        defer if (user_skills_root) |b| allocator.free(b);
        if (environ.getPosix("FRANKY_HOME")) |h| {
            user_skills_root = std.fs.path.join(allocator, &.{ h, "skills" }) catch null;
        } else if (environ.getPosix("HOME")) |h| {
            user_skills_root = std.fs.path.join(allocator, &.{ h, ".franky", "skills" }) catch null;
        }

        var loaded = skills_mod.loadAll(allocator, ioref, .{
            .explicit_root = cfg.skills_path,
            .workspace_root = workspace_skills_root,
            .user_root = user_skills_root,
        }) catch break :skills_block;
        defer {
            for (loaded.items) |*s| s.deinit(allocator);
            loaded.deinit(allocator);
        }

        var explicit_list: std.ArrayList([]const u8) = .empty;
        defer explicit_list.deinit(allocator);
        if (cfg.skills_select_csv) |csv| {
            var it = std.mem.tokenizeScalar(u8, csv, ',');
            while (it.next()) |tok| {
                const trimmed = std.mem.trim(u8, tok, " \t");
                if (trimmed.len > 0) explicit_list.append(allocator, trimmed) catch break :skills_block;
            }
        }

        var active = skills_mod.selectActive(
            allocator,
            ioref,
            loaded.items,
            pwd,
            explicit_list.items,
        ) catch break :skills_block;
        defer active.deinit(allocator);

        const section = skills_mod.renderSection(allocator, loaded.items, active.items) catch break :skills_block;
        defer allocator.free(section);

        if (section.len > 0) {
            const trimmed = std.mem.trimEnd(u8, with_skills, &std.ascii.whitespace);
            with_skills = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed, section });
            skills_owned = true;
        }
    }
    defer if (skills_owned) allocator.free(with_skills);

    // Append extra system prompt.
    if (cfg.append_system_prompt) |extra| {
        const trimmed = std.mem.trimEnd(u8, with_skills, &std.ascii.whitespace);
        const result = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed, extra });
        if (skills_owned) allocator.free(with_skills);
        return result;
    }

    return try allocator.dupe(u8, with_skills);
}

fn readWholeFileOpt(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const len = f.length(io) catch return null;
    const buf = allocator.alloc(u8, @intCast(len)) catch return null;
    const n = f.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    if (n != buf.len) {
        allocator.free(buf);
        return null;
    }
    return buf;
}
