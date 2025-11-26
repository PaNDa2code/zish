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

benchmarks on linux (hyperfine):

| test | zish | bash | zsh |
|------|------|------|-----|
| `-c exit` | 240µs | 850µs | 900µs |
| `for i in 1..10; do true; done` | 240µs | 850µs | 870µs |
| `while [ $i -lt 1000 ]; do i=$((i+1)); done` | 2.5ms | 2.5ms | 2.8ms |
| `fn() { echo $1; }; fn x; fn y` | 200µs | 850µs | 950µs |
| `a=$((1+2*3))` | 210µs | 760µs | 850µs |
| `echo x \| cat \| cat` | 1.8ms | 1.7ms | 2.1ms |

## build

```
zig build
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
