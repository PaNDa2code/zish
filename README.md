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
