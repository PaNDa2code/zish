# zish

fast, opinionated shell written in zig. for the brave.

## features

- vim mode (`set vim on`)
- git prompt (`set git_prompt on`)
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

## status

v0.5.0 - daily driver ready, expect rough edges
