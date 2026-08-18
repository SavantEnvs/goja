#!/usr/bin/env bash
#
# goja/mayhem/build.sh — build the JS lexer/parser/AST surface and the
# parse+compile+RUN interpreter surface as sanitized libFuzzer binaries, plus
# the project's KAT probe.
#
# Targets produced (one Mayhemfile each):
#   /mayhem/fuzz_parse    — parser.ParseFile (lexer/parser/AST only, no
#                            compile, no execution)
#   /mayhem/fuzz_runtime  — goja.New + Compile + RunProgram (bytecode VM,
#                            including native builtins) — the deep target
#   /mayhem/kat           — dynamically-linked known-answer probe used by
#                            mayhem/test.sh
#
# goja has no upstream fuzz target at all — both harnesses are new, written
# over the project's PUBLIC library API from mayhem/harness_*_test.go.src.
# See those files for the harness design, and mayhem/harness_runtime_test.go.src
# in particular for the VM-bounding rationale (Interrupt() + a hard
# process-level watchdog — Interrupt() alone does not stop native-builtin
# work; see mayhem/fuzz_runtime/known-findings/native-builtin-unbounded-work/).
#
# Go path is ASan-only for the libFuzzer link (as OSS-Fuzz's Go path is): the
# .a archive carries the Go fuzz code instrumented by go-118-fuzz-build, then
# clang++ links it against the libFuzzer engine.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 with no
# downgrade knob. The C/CGO shims clang compiles (the LLVMFuzzerTestOneInput
# wrapper, the CGO bridge) default to DWARF5 under clang-19, so we force them
# — and the final link — to DWARF3 via $GO_DEBUG_FLAGS. verify-repo reads the
# FIRST CU's DWARF version, which is the C shim at DWARF3, satisfying the < 4
# gate.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script
# OFFLINE. This first (online) build populates $GOMODCACHE under
# /opt/toolchains; the cache doubles as a file proxy, which GOPROXY prefers,
# so the offline re-run resolves from it. Re-running on an already-built tree
# must succeed (idempotent — every step below is safe to repeat: `cp -f`,
# `mkdir -p`, and go-118-fuzz-build/go build all overwrite their outputs).
#
# .dockerignore NOTE: unlike some sibling Go repos (e.g. gojq), goja ships no
# root .dockerignore, so there is no context-stripping trap here — the full
# upstream test suite lands in the build context unmodified (see the
# Dockerfile header).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# ASan-only for the Go libFuzzer link. An explicit empty --build-arg SANITIZER_FLAGS=
# yields a no-sanitizer (natural-crash) build, so default with `=` not `:=`.
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# DWARF3 for every clang-compiled shim + the final link (see header).
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Offline-first module resolution. $(go env GOMODCACHE) reads the pinned ENV
# from the Dockerfile, so this path is right under ANY $HOME (CI or the PATCH
# re-run).
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-118-fuzz-build rewrites the stdlib `testing` import to its own shim,
# which must be on the module graph. Order matters: tidy FIRST, then `go get`
# the shim — a trailing tidy would prune it again (nothing imports it until
# the builder generates the entrypoint). Both resolve from the module cache
# when offline.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# The harnesses ship as .go.src so they are never compiled as ordinary
# root-package files; copy them in as real _test.go files for the builder.
# Idempotent (cp -f). Both drop into their target directory's OWN, uniform
# non-test package (goja at the root, parser under parser/) — neither
# directory mixes internal/external test packages, so there is no
# go-118-fuzz-build package-collision trap here (see the harness file
# headers and the port brief's Go trap on mixed test packages).
cp -f "$SRC/mayhem/harness_runtime_test.go.src" "$SRC/mayhem_harness_runtime_test.go"
cp -f "$SRC/mayhem/harness_parse_test.go.src"   "$SRC/parser/mayhem_harness_parse_test.go"

# build_target <output-name> <fuzz-func> <package-dir>
build_target() {
  local target="$1" func="$2" pkgdir="$3"
  echo "=== building $target ($func in $pkgdir, go-118-fuzz-build) ==="
  go-118-fuzz-build -o "$SRC/mayhem-build/$target.a" -func "$func" "$pkgdir"
  # shellcheck disable=SC2086  # word-splitting of the flag lists is intended
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
      "$SRC/mayhem-build/$target.a" -o "/mayhem/$target"
  echo "built /mayhem/$target"
}

build_target fuzz_parse   FuzzMayhemParse   "$SRC/parser"
build_target fuzz_runtime FuzzMayhemRuntime "$SRC"

# ── The KAT probe used by mayhem/test.sh (NORMAL flags — it is a functional
#    oracle, not a triage artifact, so no sanitizer/fuzz instrumentation
#    here). ────────────────────────────────────────────────────────────────
# CGO_ENABLED=1 + the `import "C"` file force EXTERNAL linking so the probe is
# DYNAMICALLY linked and therefore reachable by verify-repo's LD_PRELOAD
# sabotage shim (SPEC §6.3). Assert that, so a toolchain change can't silently
# turn the probe static and weaken the oracle to a `go test`-only pass.
echo "=== building /mayhem/kat (KAT probe, cgo => dynamically linked) ==="
CGO_ENABLED=1 CGO_CFLAGS="$GO_DEBUG_FLAGS" go build -o /mayhem/kat ./mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# Go's `go test` compiles on demand, so there is no separate test-suite build
# step; mayhem/test.sh runs `go test ./...` with the project's normal flags.

echo "build.sh complete:"
ls -la /mayhem/fuzz_parse /mayhem/fuzz_runtime /mayhem/kat
