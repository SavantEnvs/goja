// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `go test` links a STATIC binary, so verify-repo's sabotage check (which
// LD_PRELOADs a shim whose constructor calls _exit(0) for non-system
// executables) cannot neuter it — a suite that only runs `go test` is
// therefore immune to the sabotage check and does not prove the oracle is
// behavioral. This probe is built with cgo (see cgo_dynamic.go) so it is
// DYNAMICALLY linked: the shim reaches it, the process becomes an instant
// no-op, it prints nothing, and test.sh's exact-match assertions below fail.
// That is what makes the oracle sabotage-detecting.
//
// It is also a real KAT, not a liveness check: it parses+compiles+runs four
// fixed JS programs through goja's public library API (the same
// goja.New/Compile/RunProgram surface the fuzz harnesses drive) and asserts
// the exact computed results. A patch that stubs the parser/compiler/VM to
// dodge a crash cannot reproduce these values.
//
// Prints four lines, which test.sh matches EXACTLY:
//
//	KAT_MAP_JOIN=<result of        [1,2,3].map(x=>x*2).join(",")>
//	KAT_JSON_STRINGIFY=<result of  JSON.stringify({a:1})>
//	KAT_REGEX_REPLACE=<result of   "aXbXc".replace(/X/g, "-")>
//	KAT_TOFIXED=<result of         (0.1+0.2).toFixed(3)>
package main

import (
	"fmt"
	"os"

	"github.com/dop251/goja"
)

// evalOne creates a fresh Runtime, evaluates src, and returns its String()
// representation. Any parse/compile/runtime error is a hard failure — this
// probe expects an exact, deterministic answer for each fixed case.
func evalOne(label, src string) string {
	rt := goja.New()
	v, err := rt.RunString(src)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: %s: %q: %v\n", label, src, err)
		os.Exit(1)
	}
	if v == nil {
		fmt.Fprintf(os.Stderr, "kat: %s: %q produced no value\n", label, src)
		os.Exit(1)
	}
	return v.String()
}

func main() {
	// 1) array map + join — everyday functional-pipeline idiom.
	fmt.Printf("KAT_MAP_JOIN=%s\n", evalOne("MAP_JOIN", `[1,2,3].map(x=>x*2).join(",")`))

	// 2) JSON.stringify over an object literal.
	fmt.Printf("KAT_JSON_STRINGIFY=%s\n", evalOne("JSON_STRINGIFY", `JSON.stringify({a:1})`))

	// 3) String.prototype.replace with a global regex.
	fmt.Printf("KAT_REGEX_REPLACE=%s\n", evalOne("REGEX_REPLACE", `"aXbXc".replace(/X/g, "-")`))

	// 4) floating point precision — Number.prototype.toFixed.
	fmt.Printf("KAT_TOFIXED=%s\n", evalOne("TOFIXED", `(0.1+0.2).toFixed(3)`))
}
