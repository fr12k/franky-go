//! franky-go — standalone binary with the go-dev extension pre-loaded.
//!
//! Wire a franky extension in ~20 lines of main.zig.
//! Everything else (agent loop, mode dispatch, skill loading) stays
//! fully controlled by franky — no forking required.
//!
//! Usage:
//!   zig build run -- --extensions go-dev "Write a Go http handler"
//!   zig build run -- --extensions go-dev --mode interactive
//!   zig build run -- --extensions go-dev "run go test ./..."

const std = @import("std");
const franky = @import("franky");
const go_dev = @import("franky-golang");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // ── 1. Register the extension in the runtime catalog ──────────
    // After this call, `--extensions go-dev` resolves to this extension
    // at startup. The extension's init_fn registers:
    //   - Tools  → merged into the agent loop's tool list
    //   - Presets → merged into the subagent PresetRegistry
    //   - Slash commands → merged into the slash registry (interactive mode)
    try franky.coding.extensions_builtin.catalog.register("go-dev", go_dev.extension);

    // ── 2. Skills go in <workspace>/skills/*.md ──────────────────
    // No code needed. Skills are auto-discovered by franky's
    // buildSystemPromptIo() from these roots:
    //   <workspace>/skills/          (highest precedence)
    //   $FRANKY_HOME/skills/
    //   ~/.franky/skills/
    //
    // Activation is deterministic — --skill NAME or auto_apply glob.

    // ── 3. Delegate to franky's mode driver ──────────────────────
    // Dispatches --mode print (default) and --mode interactive.
    // The extension tools are already in final_tools; skills are in
    // the system prompt; hooks are active.
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
    try franky.coding.modes.print.run(gpa, io, init.minimal.environ, init.environ_map, args_list.items);
}
