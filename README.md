# zish

fast, opinionated shell written in zig. for the brave.

## features

- vim mode with full text objects
- git prompt (`set git_prompt on`)
- syntax highlighting
- tab completion with common prefix
- persistent history
- aliases & functions
- `${VAR:-default}` parameter expansion
- `[[ ]]` test expressions
- pipes, redirects, `&&`, `||`
- `$(cmd)` and `$((math))`
- builtins: `cd`, `-`, `..`, `...`, `local`, `export`

## performance

benchmarks via `./bench.sh` (hyperfine):

| test | vs bash | vs zsh |
|------|---------|--------|
| variables: `x=hello; y=world; z="$x $y"; unset x` | 3.2x | 3.6x |
| functions: `greet() { echo "Hello $1"; }; greet World` | 3.3x | 3.8x |
| arithmetic: `a=5; b=3; c=$((a + b * 2))` | 3.5x | 3.8x |
| conditionals: `if [ $x -gt 10 ]; then ... fi` | 3.5x | 3.9x |
| case: `case $x in foo) echo matched;; esac` | 3.5x | 4.0x |
| for + functions: `for i in 1 2 3 4 5; do fn $i; done` | 2.5x | 2.9x |
| nested loops: `for i in 1 2 3; do for j in a b c; ...` | 1.9x | 2.0x |
| pipeline: `echo "3\n1\n2" \| sort \| head -2` | 1.8x | 2.1x |
| command substitution: `x=$(echo hello)` | 5.3x | 5.5x |

## build

```
zig build --release=fast
./zig-out/bin/zish
```

## config

```
cp example.zishrc ~/.zishrc
```

## vim mode

zish has vim-style modal editing enabled by default.

### modes

| mode | indicator | description |
|------|-----------|-------------|
| insert | `[I]` | normal typing (default) |
| normal | `[N]` | vim commands |
| visual | `[V]` | character selection |
| visual line | `[VL]` | line selection |
| replace | `[R]` | overwrite mode |

### normal mode commands

**mode entry**
| key | action |
|-----|--------|
| `i` | insert at cursor |
| `I` | insert at line start |
| `a` | append after cursor |
| `A` | append at line end |
| `o` | open line below |
| `O` | open line above |
| `s` | substitute char |
| `S` | substitute line |
| `v` | visual mode |
| `V` | visual line mode |
| `R` | replace mode |

**motions**
| key | action |
|-----|--------|
| `h` `l` | left / right |
| `j` `k` | down / up (multiline) |
| `w` `W` | word / WORD forward |
| `b` `B` | word / WORD backward |
| `e` `E` | word / WORD end |
| `0` | line start |
| `^` | first non-blank |
| `$` | line end |
| `G` | buffer end |

**operators** (combine with motions or text objects)
| key | action |
|-----|--------|
| `d` | delete |
| `c` | change (delete + insert) |
| `y` | yank (copy) |

**text objects** (use with `i` inner or `a` around)
| object | description |
|--------|-------------|
| `w` `W` | word / WORD |
| `"` `'` `` ` `` | quoted string |
| `(` `)` `b` | parentheses |
| `[` `]` | brackets |
| `{` `}` `B` | braces |
| `<` `>` | angle brackets |

**common combos**
```
ciw     change inner word
diw     delete inner word
daw     delete around word (includes space)
ci"     change inside quotes
da(     delete around parentheses
yiw     yank inner word
dd      delete line
cc      change line
yy      yank line
3dw     delete 3 words
```

**single char operations**
| key | action |
|-----|--------|
| `x` | delete char under cursor |
| `X` | delete char before cursor |
| `r` | replace single char |
| `C` | change to end of line |
| `D` | delete to end of line |
| `p` | paste after |
| `P` | paste before |

### visual mode

select text then operate:
- `d` / `x` - delete selection
- `c` / `s` - change selection
- `y` - yank selection
- `o` - swap cursor/anchor
- `Esc` - cancel

### insert mode

| key | action |
|-----|--------|
| `Esc` | back to normal |
| `Ctrl-a` | line start |
| `Ctrl-e` | line end |
| `Ctrl-u` | delete to start |
| `Ctrl-w` | delete word back |
| `Ctrl-c` | cancel |

## status

v0.5.1 - daily driver ready, expect rough edges
