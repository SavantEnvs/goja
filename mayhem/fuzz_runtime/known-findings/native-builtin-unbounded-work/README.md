# Finding: `Runtime.Interrupt()` does not bound native-builtin work — unbounded allocation/CPU hang

**Cause.** `goja`'s `Runtime.Interrupt()` is documented to only take effect
"while in JavaScript code" — the interrupted flag is checked between bytecode
instructions in `vm.run()` (`vm.go`), but a call into a native (Go-implemented)
builtin such as `Array.prototype.fill`, `Array.prototype.join`,
`String.prototype.repeat`, or `JSON.stringify` runs to completion as a single
Go function call with no interrupt checkpoint inside it. A builtin call that
materializes a huge array/string therefore cannot be stopped by
`Interrupt()`, no matter how short the deadline.

**Impact.** Any embedder that (a) runs untrusted JS through a bare
`goja.Runtime` and (b) relies on `Interrupt()` (directly or via a
`context`-based wrapper built on top of it) as its ONLY execution-time bound
is exposed to a trivial CPU/memory-exhaustion DoS from a single-line script.
No `require()`/host bindings are needed to trigger it — pure ECMAScript
builtins suffice.

**Reproducers** (each run to at least a 30s wall-clock hang with a bare
`goja.New()` + `Interrupt()` armed at 200ms; none of them return before the
hard watchdog in `mayhem/harness_runtime_test.go.src` fires at 1.5s):

- `array-fill-huge.js` — `new Array(1e9).fill(0)`
- `string-repeat-huge.js` — `"a".repeat(2000000000)`
- `json-stringify-huge.js` — `JSON.stringify(new Array(1e8).fill(0))`
- `array-join-huge.js` — `new Array(1e8).fill(1).join(',')`

Reproduce standalone (no Mayhem needed):

```go
rt := goja.New()
time.AfterFunc(200*time.Millisecond, func() { rt.Interrupt("timeout") })
rt.RunString(`new Array(1e9).fill(0)`) // does not return within the deadline
```

**Upstream fix sketch.** Either (a) document the limitation prominently next
to `Interrupt()` (currently a single sentence easy to miss) and recommend a
process/goroutine-level watchdog as the only reliable external bound, or (b)
add periodic interrupt-flag checks inside the native builtins that already
loop over attacker-controlled lengths (`Array.fill`/`join`/`repeat`/`concat`,
`JSON.stringify`, etc.) — mirroring what the bytecode loop already does. (b)
is the real fix; (a) is the minimum.

**Why this is not guarded away in the harness.** Per the port brief, hangs
must be guarded only when they are a *narrow, specific* precondition that
would otherwise stall the whole campaign — not silently avoided by
restricting the input space. This finding covers an open-ended CLASS (any
native builtin fed a huge count/length), so it cannot be "fixed" with a
one-line input guard without also disabling legitimate coverage of those
builtins. Instead, `mayhem/harness_runtime_test.go.src` layers a hard
process-level watchdog (`os.Exit` at a 1.5s total deadline) that turns each
occurrence into a fast, bounded, libFuzzer-catchable crash instead of an
unbounded hang — so the campaign keeps moving and every occurrence still gets
recorded as a finding.
