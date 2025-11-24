# TODOs

## known bugs in 4.2

### bugs in completion 
does not handle more than 1 arg
does not complete paths starting wtih ~/
probably shit ton of other bugs in it
```
[I] alice@atomman ~ $ cd rotko/zi
zish/
zigner/
[I] alice@atomman ~ $ cd rotko/zish/
[I] alice@atomman ~/rotko/zish $ ls
build.zig      README.md  spec
build.zig.zon  rnd        src
Makefile       scripts    zig-out
[I] alice@atomman ~/rotko/zish $ cd ~/rotko/z
```


### de/encryption bugs in history
warning: failed to decrypt entry: error.AuthenticationFailed, skipping
chpw only takes like 1 letter
iss a mess atm


### CRITICAL: 
ctrl+c signal kills whole tty instead of just ongoing child task. 
