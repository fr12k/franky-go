---
name: go
description: |
  Idioms and best practices for Go development. **Version target: Go 1.21+ / 1.22+.
  Covers project layout, concurrency, error handling, testing, and common pitfalls.
auto_apply: ["go.mod", "go.sum"]
---

# Go programming reference

This skill captures Go-specific idioms and pitfalls. **Default version target: Go 1.22+** with generics, `for range` improvements, and `slog` as the standard structured logger.

## Top 10 rules — if you remember nothing else

1. **`error` is an interface, not a type union.** Return `nil` for success. Use `errors.New("msg")` or `fmt.Errorf("format %v", arg)` for sentinel errors. Wrap with `fmt.Errorf("context: %w", err)` (Go 1.13+).
2. **Handle every error — never `_ =` an error value.** Linters (`errcheck`, `staticcheck`) flag unchecked returns. If truly unrecoverable, `log.Fatal(err)` in `init()` / `main()`, never in libraries.
3. **`defer` is per-statement and LIFO.** Pair every `os.Open` / `os.Create` / `http.Get` with a `defer f.Close()` on the very next line (or in the same block). For writable files, check the close error in Go 1.21+ via `defer func(){ if err := f.Close(); err != nil { … } }()`.
4. **`context.Context` is the first parameter** of every I/O-bound or cancellable function. Never store it in a struct — pass it explicitly. Use `context.Background()` for top-level, `context.TODO()` during migration.
5. **Slices are fat pointers (ptr, len, cap).** `append` may reallocate. Never retain a pointer into a slice after an `append` that may grow it. Use `s = append(s, x)` idiom — always assign the result.
6. **Goroutines are cheap but not free.** Spawn them with `go f()` and use `sync.WaitGroup` or errgroup to join them. Know where each goroutine ends. Leaked goroutines are the #1 runtime failure pattern.
7. **Channels for signaling, mutexes for state.** Use `chan struct{}` for events (0 bytes). Use `sync.Mutex` / `sync.RWMutex` for mutable shared state. Channel-based state is often over-engineering.
8. **`interface{}` is `any` (Go 1.18+).** Prefer type-safe generics over `any` for containers (Go 1.18+). For heterogeneous data, prefer type switches over reflection.
9. **`gofmt` is mandatory, `go vet` is baseline.** Run `go fmt ./...` before every commit. Run `go vet ./...` in CI. Use `staticcheck` for deeper linting. `go mod tidy` keeps `go.mod` clean.
10. **Tests live in `*_test.go` files alongside the code they test.** Table-driven tests with `t.Run(name, fn)` subtests are the standard. Use `testing.F` for fuzzing (Go 1.18+). Use `testing/slogtest` for structured log testing.

---

## Project layout (standard Go)

```
myproject/
├── cmd/            — Main applications (one dir per binary)
│   └── myapp/
│       └── main.go
├── internal/       — Private packages (not importable outside module)
│   └── server/
├── pkg/            — Public library packages (optional)
├── api/            — API definitions (OpenAPI, protobuf, etc.)
├── web/            — Web assets (HTML, CSS, JS)
├── configs/        — Configuration file templates
├── scripts/        — Build scripts
├── test/           — External test data
├── go.mod
├── go.sum
├── Makefile        — Optional: wrap go commands
└── README.md
```

Key conventions:
- `cmd/` only contains `func main()`. Business logic goes in `internal/` or `pkg/`.
- `internal/` packages are module-private (Go toolchain enforces this).
- Test packages use `_test` suffix in the package declaration for black-box testing: `package mypkg_test`.

---

## Error handling

### Basic patterns

```go
// Sentinel error
var ErrNotFound = errors.New("not found")

func Find(id int) (*Record, error) {
    if id < 0 {
        return nil, ErrNotFound
    }
    return &Record{ID: id}, nil
}

// Wrapping with context (Go 1.13+)
func LoadConfig(path string) (*Config, error) {
    f, err := os.Open(path)
    if err != nil {
        return nil, fmt.Errorf("open config %s: %w", path, err)
    }
    defer f.Close()
    // …
}

// Unwrapping
if errors.Is(err, ErrNotFound) { … }
var e *os.PathError
if errors.As(err, &e) { … }
```

### Go 1.20+ joined errors

```go
err = errors.Join(err1, err2)  // multi-error; Is/As check each component
```

### Defer-close with error check (Go 1.21+)

```go
func writeFile(path string, data []byte) (err error) {
    f, err := os.Create(path)
    if err != nil {
        return err
    }
    defer func() {
        if cerr := f.Close(); cerr != nil && err == nil {
            err = cerr  // propagate close error only if no prior error
        }
    }()
    _, err = f.Write(data)
    return
}
```

---

## Concurrency

### Goroutine lifecycle with errgroup

```go
import "golang.org/x/sync/errgroup"

g, ctx := errgroup.WithContext(context.Background())
for _, item := range items {
    item := item  // capture loop variable (pre-Go 1.22, not needed in 1.22+)
    g.Go(func() error {
        return process(ctx, item)
    })
}
if err := g.Wait(); err != nil {
    log.Printf("one or more goroutines failed: %v", err)
}
```

### Channel patterns

```go
// Signal-only channel
done := make(chan struct{})
go func() {
    doWork()
    close(done)
}()
<-done  // wait for completion

// Fan-out / fan-in
jobs := make(chan Job, 100)
results := make(chan Result, 100)

// Worker pool
var wg sync.WaitGroup
for i := 0; i < numWorkers; i++ {
    wg.Add(1)
    go func() {
        defer wg.Done()
        for j := range jobs {
            results <- process(j)
        }
    }()
}
close(jobs)  // signal no more jobs
go func() {
    wg.Wait()
    close(results)  // close results after all workers are done
}()
```

### Mutex guard

```go
type Counter struct {
    mu    sync.Mutex
    value int
}

func (c *Counter) Inc() {
    c.mu.Lock()
    defer c.mu.Unlock()
    c.value++
}
```

---

## Context lifecycle

```go
// Always pass ctx as first parameter
func handler(ctx context.Context, r *http.Request) (*Response, error) {
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()  // <-- EVERY context.With* MUST pair with a defer cancel()

    result, err := queryDatabase(ctx, r.URL.Query().Get("id"))
    if err != nil {
        return nil, fmt.Errorf("query: %w", err)
    }
    return result, nil
}

// In an HTTP handler, the request context is the parent:
func MyHandler(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    // …
}
```

---

## Testing

### Table-driven test

```go
func TestAdd(t *testing.T) {
    t.Parallel()  // run sub-groups in parallel too
    tests := []struct {
        name string
        a, b int
        want int
    }{
        {"positive", 2, 3, 5},
        {"negative", -1, 1, 0},
        {"zero", 0, 0, 0},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got := Add(tt.a, tt.b)
            if got != tt.want {
                t.Errorf("Add(%d, %d) = %d, want %d", tt.a, tt.b, got, tt.want)
            }
        })
    }
}
```

### Integration tests with build tag

```go
// file: db_test.go
//go:build integration

package db_test

func TestPostgresRoundTrip(t *testing.T) {
    t.Skip("requires postgres: set INTEGRATION_DB env")
    // …
}
// Run: go test -tags=integration ./...
```

### Fuzz test (Go 1.18+)

```go
func FuzzParse(f *testing.F) {
    f.Add("valid input")
    f.Add("")
    f.Fuzz(func(t *testing.T, input string) {
        result, err := Parse(input)
        if err == nil && result == nil {
            t.Error("expected result or error")
        }
    })
}
```

---

## Common pitfalls

### Slice aliasing

```go
// BUG: append may share backing array with original
original := []int{1, 2, 3}
sub := original[:2]      // len=2, cap=3
sub = append(sub, 4)     // overwrites original[2]!
// FIX: use copy() or full expression sub := original[:2:2] (cap=2)
```

### Loop variable capture (pre-Go 1.22)

```go
// Pre-Go 1.22 bug:
for _, v := range items {
    go func() {
        fmt.Println(v)  // all goroutines see the LAST value of v
    }()
}
// Pre-Go 1.22 fix:
for _, v := range items {
    v := v  // re-declare in loop body
    go func() { fmt.Println(v) }()
}
// Go 1.22+ behaves correctly — no capture bug.
```

### Map not safe for concurrent access

```go
var m map[string]int
// BUG: concurrent read + write = panic
// FIX: sync.RWMutex or sync.Map
```

### `json.Unmarshal` into nil map

```go
var m map[string]int
// This works: json fills in the map
json.Unmarshal([]byte(`{"a":1}`), &m)
// But writing to m without Unmarshal panics:
// m["b"] = 2  // panic: assignment to entry in nil map
```

### Never store `*http.Client` with per-request config

```go
// BAD: don't embed auth in Client
type Client struct {
    http.Client
    token string
}
// GOOD: set auth per request via Transport or headers
```

---

## Module management

```sh
go mod init example.com/myproject
go mod tidy                                     # add missing, remove unused
go mod download                                 # cache dependencies
go mod verify                                   # check integrity
go list -m all                                  # list all deps
go list -u -m all                               # check available upgrades
go get example.com/pkg@v1.2.3                   # upgrade to specific version
go work init                                    # Go 1.18+ workspace for multi-module
```

---

## Diagnostic tools

- `go fmt ./...` — formatting
- `go vet ./...` — static analysis (always run before commit)
- `staticcheck ./...` — deeper linter (golangci-lint frontend)
- `go test -race ./...` — race detector
- `go test -cover ./...` — coverage
- `go tool pprof` — CPU / memory profiling
- `go tool trace` — execution tracing
- `slog` — structured logging (std library, Go 1.21+)

---

## When in doubt

- Effective Go (https://go.dev/doc/effective_go) — still mostly current.
- Go FAQ (https://go.dev/doc/faq) — answers design questions.
- Go 1.22 Release Notes — for latest `for range` and `slog` details.
- `go doc` / `go help` — always current for the installed toolchain.
