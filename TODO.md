advanced_spec.sh  basic_spec.sh  spec_helper.sh
[I] alice@atomman ~/rotko/zish $ git status
On branch main
Your branch is up to date with 'rotko/main'.

Changes to be committed:
  (use "git restore --staged <file>..." to unstage)
	deleted:    TODO.md
	modified:   src/Shell.zig
	modified:   src/crypto.zig
	modified:   src/eval.zig
	modified:   src/history.zig
	modified:   src/history_log.zig

Changes not staged for commit:
  (use "git add/rm <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	deleted:    rnd/comptime_opts.zig
	deleted:    rnd/history_fast.zig
	deleted:    rnd/history_simple.zig
	deleted:    rnd/lexer_fast.zig
	deleted:    rnd/lockfree.zig
	deleted:    rnd/pipeline_fast.zig
	deleted:    rnd/simd.zig
	deleted:    rnd/strings.zig

[I] alice@atomman ~/rotko/zish $ git add rnd


-> predictive git tab completion
