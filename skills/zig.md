---
name: zig
description: |
  This skill captures Zig-specific idioms and pitfalls. **Default version target: Zig 0.17-dev (master).
auto_apply: ["build.zig", "build.zig.zon"]
---

# Zig 0.16+ / 0.17-dev programming reference

This skill captures Zig-specific idioms and pitfalls. **Default version target: Zig 0.17-dev (master).** Where the syntax differs from older books or 0.13/0.14 stable, this file flags it explicitly with `⚠️ VERSION`.

## Top 10 rules — if you remember nothing else

1. **Pair every `alloc`/`create` with a `defer free`/`defer destroy` on the very next line.** Multi-step constructors that hand the resource back to the caller use `errdefer` instead, so success paths transfer ownership.
2. **Never return a pointer to a stack-local.** It compiles but is UB at runtime. Heap-allocate (and document who frees) or take a caller-provided buffer.
3. **Errors are values; `_ = mayFail()` won't compile.** Use `try` (propagate), `catch |err| {…}` (handle), or `if (mayFail()) |val| {…} else |err| {…}`.
4. **`const` by default, `var` only when actually mutated.** The compiler enforces both directions.
5. **Function args are immutable, including `self`.** To mutate, accept `*T` and assign through `ptr.*` / `self.field = …`.
6. **Pointers are non-nullable.** Use `?T` for "may be null"; unwrap with `if (x) |v|`, `orelse default`, or `.?` (panics if null in Debug/ReleaseSafe).
7. **Switch must be exhaustive.** Plain `union` can't be switched — use `union(enum)`.
8. **No hidden allocations.** Any function that allocates takes an `Allocator` arg. Follow this convention in your own code.
9. **Use `std.testing.allocator` in tests** — catches leaks/double-frees that production allocators won't.
10. **Strings: `[]const u8` is the default**; literals are `*const [N:0]u8` (sentinel-terminated) but coerce to slices. Iterate with `for` for bytes, `std.unicode.Utf8View` for codepoints.

---

## Memory & allocators

Three memory spaces:

- **Global data** — string literals + comptime-known consts; you can't touch it.
- **Stack** — auto-freed at scope exit, fixed-size only, **small**. Returning a pointer to a stack local = UB.
- **Heap** — allocator-mediated, you free it.

Zig's promise: **no hidden allocations**. If a function allocates, it takes an `Allocator` parameter.

### DebugAllocator with leak-check

```zig
var gpa = std.heap.DebugAllocator(.{}){};
defer _ = gpa.deinit();          // reports leaks at exit
const a = gpa.allocator();
```
⚠️ VERSION: `DebugAllocator` is the 0.14+ name. `GeneralPurposeAllocator` may still alias it on 0.17-dev master, but prefer `DebugAllocator`.

### Slice alloc / free

```zig
const buf = try a.alloc(u8, 50);
defer a.free(buf);
@memset(buf[0..], 0);
```

### Single-item alloc / free

```zig
const u = try a.create(User);
defer a.destroy(u);
u.* = User.init(0, "pedro");
```

### Arena (alloc many, free once)

```zig
var aa = std.heap.ArenaAllocator.init(gpa.allocator());
defer aa.deinit();
const a = aa.allocator();
_ = try a.alloc(u8, 5);
_ = try a.alloc(u8, 10);   // single deinit frees both
```

Use arenas when many small allocations share a lifetime (parser tree, request scope, build step).

### FixedBufferAllocator (no heap)

```zig
var buf: [10]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);
const a = fba.allocator();
```

Useful for embedded / tests / "this allocation must not heap".

### Test allocator

```zig
test "no leaks" {
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 10);
    defer a.free(buf);   // omit this line and the test fails with "memory leaked"
}
```

### Other stdlib allocators

- `std.heap.page_allocator` — direct from OS, page-sized.
- `std.heap.c_allocator` — wraps `malloc`/`free`; needs `-lc` link, otherwise linker error.
- `std.heap.ThreadSafeFixedBufferAllocator` — thread-safe FBA.

---

## Error handling

Errors are payload-less values. Function returns `!T` (or `MyError!T`) = "error or T".

### Propagate (most common)

```zig
const file = try cwd.openFile(io, "foo.txt", .{});
```

### Catch with handler block

```zig
const file = cwd.openFile(io, "foo.txt", .{}) catch |err| {
    log.err("open failed: {}", .{err});
    return err;
};
```

### Catch with default value

```zig
const n = parseU64(s, 10) catch 13;
```

### Named error set

```zig
pub const ReadError = error{ TlsFailure, EndOfStream, ConnectionResetByPeer };
pub fn fill(c: *Conn) ReadError!void { … }
```

A smaller error set coerces into a superset implicitly. Going the other way needs explicit conversion.

### Switch over error variants

```zig
if (parse(s)) |val| use(val)
else |err| switch (err) {
    error.InvalidName => …,
    error.Timeout => …,
    else => return err,
}
```

### Partial-construction cleanup with `errdefer`

```zig
fn createUser(db: Database, a: Allocator) !*User {
    const u = try a.create(User);
    errdefer a.destroy(u);   // free only if a later step fails
    try db.registerUser(u);
    return u;                // success → errdefer skipped, u handed to caller
}
```

### Gotchas

- `_ = mayFail();` is a compile error ("error set is discarded").
- `try` always returns from the **current function** on error — putting `try` deep in a helper can cause early returns you didn't expect.
- `catch` doesn't capture by default — use `catch |err| { … }` to bind the error value.
- `MyError!T` puts errors on the **left** of `!`, value on the right.
- Errors are payload-less — to carry context, log it, store in `last_error_*` fields, or wrap.

---

## Pointers & optionals

Two pointer kinds:

- **Single-item** `*T` — created with `&x`. Deref with `ptr.*`.
- **Many-item** `[*]T` — mostly internal; **slices `[]T` are the user-facing version** (pointer + length).

`const`-ness flows from the pointee: `*const T` (can't write through) vs `*T` (can write).

### Take address / deref / mutate

```zig
var n: u8 = 5;
const p = &n;        // type *u8
p.* = 6;             // mutate through pointer
```

### Pass-by-pointer for mutation

```zig
fn add2(x: *u32) void { x.* = x.* + 2; }
var v: u32 = 4;
add2(&v);            // v is now 6
```

### Method call through pointer auto-derefs

```zig
const u = try a.create(User);
u.printName(out);        // not u.*.printName — same thing
```

### Optional unwrapping (3 ways)

```zig
if (maybe) |v| { use(v); }              // 1. capture-if
const v = maybe orelse default_val;     // 2. orelse
const v = maybe.?;                      // 3. assert non-null (panics if null)
```

### `?*T` vs `*?T`

Read left-to-right:

- `?*T` — optional pointer (pointer-or-null).
- `*?T` — pointer to an optional (the optional itself lives behind the pointer).

These are different types.

---

## Structs, methods, unions

A `.zig` file *is* a struct. `init()` / `deinit()` are conventional names — not language keywords. Types must be `const` or `comptime`; you can't `var Foo = struct{…}`.

### Struct + method + immutable self

```zig
const User = struct {
    id: u64,
    name: []const u8,

    pub fn init(id: u64, name: []const u8) User {
        return .{ .id = id, .name = name };
    }

    pub fn printName(self: User, w: *std.Io.Writer) !void {
        try w.print("{s}\n", .{self.name});
    }
};
```

### Mutating method needs `*Self`

```zig
const Vec3 = struct {
    x: f32, y: f32, z: f32,

    pub fn twice(self: *Vec3) void {
        self.x *= 2;  self.y *= 2;  self.z *= 2;
    }
};
```

### Anonymous struct literal (type inferred from context)

```zig
try out.print("{s} = {d}\n", .{name, value});  // .{...} is anon struct
return .{ .x = 1, .y = 2 };                    // type inferred from return
```

### Tagged union (required for switching)

```zig
const Shape = union(enum) {
    circle: f32,    // radius
    square: f32,    // side
};
switch (s) {
    .circle => |r| { … },
    .square => |side| { … },
}
```

### Switch with capture / range / else

```zig
const label = switch (level) {
    0...25 => "beginner",
    26...75 => "intermediary",
    else => @panic("unexpected level"),
};
```

### `defer` / `errdefer` semantics

- Both run in **LIFO** order.
- `defer` runs at end of the **current scope** (block), on every path including errors.
- `errdefer` runs at end of scope **only on error paths**.

```zig
fn doThing() !void {
    const r = try acquire();
    defer release(r);          // runs always
    errdefer log.err("oops");  // runs only on error paths

    try mayFail();             // if this errors → errdefer + defer; if not → defer only
}
```

### Type casts

- `@as(u32, x)` — safe widening or no-op cast.
- `@intCast(x)` / `@intFromFloat(x)` / `@floatFromInt(x)` — narrowing/lossy.
- `@ptrCast(x)` — pointer reinterpretation (unsafe).

### Type-inference dot

`.SomeEnum`, `.{…}`, `.field` — all rely on the compiler inferring the type from context (function arg type, return type, annotation).

### Gotchas

- Function args, including `self`, are **immutable**. To mutate fields → `self: *T`.
- `pub` on the struct doesn't make methods public — each `pub fn` needs its own.
- Switch must cover every variant (or use `else`).
- Plain `union` can't be switched — needs `union(enum)`.

---

## Tests

Tests live in `test "name" { … }` blocks anywhere in any `.zig` file. `zig test foo.zig` or `zig build test` runs them.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "add works" {
    try expect(add(2, 2) == 4);
}

test "no leaks" {
    const a = std.testing.allocator;       // strict — catches leaks/double-frees
    const buf = try a.alloc(u8, 10);
    defer a.free(buf);
}

test "specific error" {
    try std.testing.expectError(error.OutOfMemory, allocTooMuch(a));
}
```

### Equality helpers

- `try std.testing.expectEqual(want, got)` — scalars, structs.
- `try std.testing.expectEqualSlices(u8, &a, &b)` — arrays/slices (`expectEqual` doesn't work on these).
- `try std.testing.expectEqualStrings(s1, s2)` — prints a diff on failure.

### Gotchas

- Every `expect*` call returns `!void` — must be `try`'d.
- `expectEqual` doesn't compare arrays/slices element-by-element. Use `expectEqualSlices`.
- `std.testing.allocator` is much stricter than `DebugAllocator`. Use it religiously.

---

## Build system

`build.zig` is a Zig program that exposes `pub fn build(b: *std.Build) void`. The compiler IS the build system; no CMake/Make.

### Skeleton (0.16+ with `root_module` indirection)

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(exe);              // ← MUST do this or no artifact emitted

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the project");
    run_step.dependOn(&run.step);
}
```

### Test step

```zig
const t = b.addTest(.{
    .name = "tests",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
    }),
});
const run_t = b.addRunArtifact(t);
b.step("test", "Run tests").dependOn(&run_t.step);
```

### User option

```zig
const debug = b.option(bool, "debug", "Enable debug mode") orelse false;
// CLI: zig build -Ddebug=true
```

### Build modes

- `.Debug` — default; safety + debug info, slow.
- `.ReleaseSafe` — optimized + safety checks. Good production default.
- `.ReleaseFast` — optimized, no safety. Maximum speed.
- `.ReleaseSmall` — optimized for size.

### Cross-compile

Set `.target = std.Target.Query{ … }` (or `b.standardTargetOptions(.{})` for CLI override) instead of `b.graph.host`. One-line target swap; no toolchain juggling.

### Link C libs

```zig
exe.root_module.linkSystemLibrary("png", .{});
exe.root_module.link_libc = true;
```

⚠️ VERSION: pre-0.14 wrote `exe.linkSystemLibrary("png")` directly on the `Compile` object. **Won't compile on 0.14+/0.17-dev.** Everything goes through `exe.root_module.*` now.

### Gotchas

- Forgetting `b.installArtifact(x)` → artifact silently discarded.
- Use `b.path("src/foo.zig")` (lazy path), not raw strings.
- Steps don't run unless something depends on them or you invoke them by name.
- `@import("builtin")` in `build.zig` reflects the build host, not the target.

---

## Debugging

Two strategies: print debugging and a debugger (LLDB/GDB).

### Quick stderr print (no writer ceremony, no flush)

```zig
std.debug.print("n={d}, name={s}\n", .{n, name});
```

Always pass print args as an anonymous tuple `.{a, b}`, not raw `(a, b)`.

### Stdout print (needs writer + buffer + flush)

```zig
pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    try out.print("Result: {d}\n", .{x});
    try out.flush();           // ← FORGETTING THIS = silent / truncated output
}
```

### Format specifiers

- `{d}` — int / float.
- `{s}` — string.
- `{c}` — char (byte).
- `{p}` — pointer.
- `{x}` / `{X}` — hex (lower / upper).
- `{any}` — auto / generic any-type.
- `{}` — default.

### Reflection

- `@TypeOf(x)` — static type at compile time.
- Print with `{any}` or `{}`.

### Debugger basics

```sh
zig build-exe foo.zig         # Debug mode preserves debug info
lldb ./foo
(lldb) b main
(lldb) run
(lldb) n          # next
(lldb) s          # step in
(lldb) p name
(lldb) frame variable
```

Compiling in `Release*` strips info; recompile in `Debug` if locals don't show.

### Gotchas

- `std.debug.print` writes to **stderr**, not stdout — and bypasses the buffered writer.
- Forgetting `try out.flush()` after stdout writes → output appears truncated.

---

## Naming & style (stdlib conventions)

- `snake_case` — fields, functions, locals, file names.
- `PascalCase` — types, type-returning functions, structs, error sets.
- `SCREAMING_SNAKE_CASE` — true constants only (rare in idiomatic Zig).
- `pub` exposes outside the module / file.
- `///` doc comment (above decl), `//!` top-of-file doc.
- One `.zig` file = one module = one (anonymous) struct.

---

## 0.17-dev (master) deltas to watch for

The book targets Zig **0.16.0**. franky/franky-do projects in this workspace target **0.17-dev master**. Expect these gotchas:

- **`std.io` → `std.Io` rename is done.** If you find `std.io.getStdOut()` / `std.io.Reader` / `std.io.getStdIn()` in older snippets, translate to `std.Io.File.stdout()` / `std.Io.Reader` / `std.Io.File.stdin()`.
- **`main` signature**: `pub fn main(init: std.process.Init) !void` is the new shape. The `init` param threads the IO context into writers (`writer(init.io, &buf)`). Old `pub fn main() !void` may still work but locks you out of the new IO API.
- **Writer is buffered + has explicit `.interface`**: get a file (`std.Io.File.stdout()`), make a writer with a buffer (`.writer(init.io, &buf)`), grab `&w.interface`, `print` then **`flush`**. This is THE most common source of "where did my output go" bugs on 0.17-dev.
- **Allocator name**: `std.heap.DebugAllocator(.{}){}`. `GeneralPurposeAllocator` is the old name and may still alias.
- **Build system**: linking + target/optimize go through `exe.root_module.*` (since 0.14). Pre-0.14 build scripts that attach things directly to `Compile` won't compile.
- **ArrayList API churn**: `ArrayList(T)` vs `ArrayListUnmanaged(T)` — the unmanaged variant takes the allocator on each call. Don't trust pre-0.14 snippets.
- **File I/O**: `std.Io.Dir.cwd().openFile(io, path, .{})` — `io` context is the first arg.

When the book shows something that doesn't compile, 90% of the time it's the writer/IO interface. Check `std.Io` first.

---

## Built-ins quick reference

Stable across 0.13 → 0.17-dev:

- `@import("std")`, `@import("builtin")`, `@import("foo.zig")`
- `@TypeOf(x)`, `@typeInfo(T)`, `@typeName(T)`
- `@as(T, x)`, `@intCast`, `@intFromFloat`, `@floatFromInt`, `@ptrCast`, `@intFromPtr`, `@ptrFromInt`
- `@memset(slice, byte)`, `@memcpy(dst, src)`
- `@panic(msg)`, `@compileError(msg)`, `@compileLog(...)` (debug-only)
- `@field(s, "name")`, `@hasField(T, "name")`, `@hasDecl(T, "name")`
- `@max(a, b)`, `@min(a, b)`, `@abs(x)`
- `@sizeOf(T)`, `@alignOf(T)`

---

## Concurrency footguns (lessons from real audits)

### Wait loops MUST sleep

```zig
// ❌ pegs a CPU core to 100% until the condition flips:
while (counter.load(.acquire) > 0) {}

// ✅ libc-conditional 1ms nanosleep:
while (counter.load(.acquire) > 0) {
    if (@import("builtin").link_libc) {
        const ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&ts, null);
    } else {
        std.Thread.yield() catch {};
    }
}

// ✅ even better when interruptible: `std.Io.Event.waitTimeout`
//    with an event the producer signals on completion (no polling).
```

The empty-`while` form looks innocent in shutdown code but burns the core during multi-second model calls. Always sleep. ⚠️ VERSION: `std.Thread.sleep` was removed in 0.17-dev; use `std.c.nanosleep` (libc) or `std.Io.Event.waitTimeout`.

### `catch return` voids the entire `errdefer` chain

`errdefer` only fires when the *current function* returns an **error union**. A plain `return` in a void/non-error context does NOT trigger errdefer:

```zig
// ❌ team_owned leaks if channel dupe fails:
const team_owned = a.dupe(u8, team) catch return;
errdefer a.free(team_owned);                   // ← dead — `catch return` already happened
const channel_owned = a.dupe(u8, channel) catch return;  // skips the errdefer above
errdefer a.free(channel_owned);
```

```zig
// ✅ match `try` + `errdefer` — errdefer fires on the !void return:
fn build(a: Allocator, team: []const u8, channel: []const u8) !Args {
    const team_owned = try a.dupe(u8, team);
    errdefer a.free(team_owned);
    const channel_owned = try a.dupe(u8, channel);
    errdefer a.free(channel_owned);
    return .{ .team = team_owned, .channel = channel_owned };
}
```

### Locals shadowed by same-name `const`s

After refactoring/extraction, a parsed CLI flag at the top of a function can be silently re-declared as `const … = false;` later in the body. The compiler doesn't warn about this — local-shadowing-local is legal in Zig.

```zig
// ❌ refactor rot — argv flag silently dropped:
var ask_all_flag = false;
while (i < args.len) : (i += 1) {
    if (mem.eql(u8, args[i], "--ask-all")) ask_all_flag = true;
}
// ... 200 lines later ...
const ask_all_flag = false;   // ← shadows the var, ignores argv
const ask_all = resolveAskAll(env, ask_all_flag);
```

When auditing, grep for re-declarations of CLI-flag names. The fix is usually to thread the flag through a function parameter rather than recomputing inside.

---

## Auditing tip — cross-check before editing

The patterns in this skill are a strong filter, but **before applying a fix from any pattern-based audit, verify the claim against the actual code path**. Common false positives:

- **"`abort()` is fire-and-forget"** — check the upstream `pub fn abort` for a `t.join()` call. If join is there, the post-abort transcript read is safe.
- **"`errdefer X` is dead code"** — trace every `try` that follows. If any of them can fail, errdefer fires; not dead.
- **"partial-construction leak in struct literal"** — trace which `try`s are inside the literal vs. outside. The `errdefer` for fields built before the literal still fires when a `try` inside the literal errors.

Pattern: read the cited line range + 5 lines on each side, then trace the actual error/success paths before editing. The cost of one false-positive edit is high; the cost of one second of cross-checking is nearly zero.

## When in doubt

- For idioms not covered here, check the book at https://github.com/pedropark99/zig-book — it's the source for this skill.
- For 0.17-dev API specifics, the master stdlib is in `~/.zig/lib/std/` (or wherever your Zig install lives). `std.Io` is the most-likely source of API churn.
- The franky/franky-do codebases under `/Users/.../franky/` are real-world Zig 0.17-dev examples — read them when stuck on patterns this skill skips (sub-agents, channels, vendored HTTP client).