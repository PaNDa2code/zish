#!/bin/sh
# Shell benchmark with correctness validation
#
# Methodology:
# - Script runs from /bin/sh for neutral execution environment
# - All shells run with --norc/--noprofile to skip user config
# - hyperfine with -N (shell=none) to avoid wrapper shell overhead
# - Correctness validated before benchmarking (zish output must match bash)
# - Each benchmark runs with warmup to stabilize caches
#
# Why zish is faster:
# - Static binary: no dynamic linker, no shared library loading
# - Stack-allocated buffers: echo/test builtins avoid malloc in loops
# - Minimal initialization: no readline, job control setup for -c mode

set -e

ZISH="./zig-out/bin/zish"
BASH="bash --norc --noprofile"
ZSH="zsh --no-rcs"
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    local zish_out bash_out

    zish_out=$($ZISH -c "$cmd" 2>&1)
    bash_out=$(bash --norc --noprofile -c "$cmd" 2>&1)

    if [ "$zish_out" != "$bash_out" ]; then
        echo "FAIL: $name"
        echo "  zish: $zish_out"
        echo "  bash: $bash_out"
        FAIL=1
        return 1
    fi
    return 0
}

bench() {
    local name="$1"
    local cmd="$2"

    check "$name" "$cmd" || return 1

    echo "$name"
    hyperfine --warmup 3 -N \
        "$ZISH -c '$cmd'" \
        "$BASH -c '$cmd'" \
        "$ZSH -c '$cmd'" \
        2>&1 | grep -E '(Summary|faster)'
    echo ""
}

echo "=== Shell Benchmark ==="
echo "All shells run with --norc/--noprofile (no user config)"
echo ""

bench "1. VARIABLES" 'x=hello; y=world; z="$x $y"; unset x; echo $z'
bench "2. FUNCTIONS" 'greet() { echo "Hello $1"; }; greet World; greet User'
bench "3. ARITHMETIC" 'a=5; b=3; c=$((a + b * 2)); d=$((c / 2)); echo $d'
bench "4. CONDITIONALS" 'x=5; if [ $x -gt 10 ]; then echo big; elif [ $x -gt 3 ]; then echo medium; else echo small; fi'
bench "5. CASE" 'x=foo; case $x in foo) echo matched;; bar) echo bar;; *) echo default;; esac'
bench "6. FOR+FUNC" 'double() { echo $(($1 * 2)); }; for i in 1 2 3 4 5; do double $i; done'
bench "7. CMD SUBST" 'x=$(echo hello); y=$(echo world); echo "$x $y"'
bench "8. NESTED LOOPS" 'for i in 1 2 3; do for j in a b c; do echo "$i$j"; done; done'

# Pipeline needs special handling (zsh echo differs)
echo "9. PIPELINE"
hyperfine --warmup 3 -N \
    "$ZISH -c 'echo -e \"3\n1\n2\" | sort | head -2'" \
    "$BASH -c 'echo -e \"3\n1\n2\" | sort | head -2'" \
    "$ZSH -c 'echo \"3\n1\n2\" | sort | head -2'" \
    2>&1 | grep -E '(Summary|faster)'
echo ""

echo "=== Benchmark Complete ==="
[ $FAIL -eq 0 ] && echo "All correctness checks passed" || echo "SOME CHECKS FAILED"
exit $FAIL
