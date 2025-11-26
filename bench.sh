#!/bin/bash
# Real-world shell benchmark script

echo "=== Comprehensive Shell Benchmark ==="
echo ""

# Test shells
ZISH="./zig-out/bin/zish"
SHELLS=("$ZISH" "bash" "zsh")

echo "1. VARIABLE OPERATIONS (set, read, unset)"
hyperfine --warmup 3 -N \
  "$ZISH -c 'x=hello; y=world; z=\"\$x \$y\"; unset x; echo \$z'" \
  "bash -c 'x=hello; y=world; z=\"\$x \$y\"; unset x; echo \$z'" \
  "zsh -c 'x=hello; y=world; z=\"\$x \$y\"; unset x; echo \$z'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "2. ALIAS OPERATIONS"
hyperfine --warmup 3 -N \
  "$ZISH -c 'alias ll=\"ls -la\"; alias; unalias ll'" \
  "bash -c 'alias ll=\"ls -la\"; alias; unalias ll'" \
  "zsh -c 'alias ll=\"ls -la\"; alias; unalias ll'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "3. FUNCTION DEFINITION AND CALL"
hyperfine --warmup 3 -N \
  "$ZISH -c 'greet() { echo \"Hello \$1\"; }; greet World; greet User'" \
  "bash -c 'greet() { echo \"Hello \$1\"; }; greet World; greet User'" \
  "zsh -c 'greet() { echo \"Hello \$1\"; }; greet World; greet User'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "4. ARITHMETIC OPERATIONS"
hyperfine --warmup 3 -N \
  "$ZISH -c 'a=5; b=3; c=\$((a + b * 2)); d=\$((c / 2)); echo \$d'" \
  "bash -c 'a=5; b=3; c=\$((a + b * 2)); d=\$((c / 2)); echo \$d'" \
  "zsh -c 'a=5; b=3; c=\$((a + b * 2)); d=\$((c / 2)); echo \$d'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "5. CONDITIONALS (if/elif/else)"
hyperfine --warmup 3 -N \
  "$ZISH -c 'x=5; if [ \$x -gt 10 ]; then echo big; elif [ \$x -gt 3 ]; then echo medium; else echo small; fi'" \
  "bash -c 'x=5; if [ \$x -gt 10 ]; then echo big; elif [ \$x -gt 3 ]; then echo medium; else echo small; fi'" \
  "zsh -c 'x=5; if [ \$x -gt 10 ]; then echo big; elif [ \$x -gt 3 ]; then echo medium; else echo small; fi'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "6. CASE STATEMENT"
hyperfine --warmup 3 -N \
  "$ZISH -c 'x=foo; case \$x in foo) echo matched;; bar) echo bar;; *) echo default;; esac'" \
  "bash -c 'x=foo; case \$x in foo) echo matched;; bar) echo bar;; *) echo default;; esac'" \
  "zsh -c 'x=foo; case \$x in foo) echo matched;; bar) echo bar;; *) echo default;; esac'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "7. FOR LOOP WITH FUNCTION CALLS"
hyperfine --warmup 3 -N \
  "$ZISH -c 'double() { echo \$((\\$1 * 2)); }; for i in 1 2 3 4 5; do double \$i; done'" \
  "bash -c 'double() { echo \$((\$1 * 2)); }; for i in 1 2 3 4 5; do double \$i; done'" \
  "zsh -c 'double() { echo \$((\$1 * 2)); }; for i in 1 2 3 4 5; do double \$i; done'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "8. COMMAND SUBSTITUTION"
hyperfine --warmup 3 -N \
  "$ZISH -c 'x=\$(echo hello); y=\$(echo world); echo \"\$x \$y\"'" \
  "bash -c 'x=\$(echo hello); y=\$(echo world); echo \"\$x \$y\"'" \
  "zsh -c 'x=\$(echo hello); y=\$(echo world); echo \"\$x \$y\"'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "9. COMPLEX PIPELINE"
hyperfine --warmup 3 -N \
  "$ZISH -c 'echo -e \"3\\n1\\n2\" | sort | head -2'" \
  "bash -c 'echo -e \"3\\n1\\n2\" | sort | head -2'" \
  "zsh -c 'echo \"3\\n1\\n2\" | sort | head -2'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "10. NESTED LOOPS (stress test)"
hyperfine --warmup 3 -N \
  "$ZISH -c 'for i in 1 2 3; do for j in a b c; do echo \"\$i\$j\"; done; done'" \
  "bash -c 'for i in 1 2 3; do for j in a b c; do echo \"\$i\$j\"; done; done'" \
  "zsh -c 'for i in 1 2 3; do for j in a b c; do echo \"\$i\$j\"; done; done'" \
  2>&1 | grep -E '(zish|bash|zsh|Summary|faster)'

echo ""
echo "=== Benchmark Complete ==="
