## completion
- fix path completion to have one first cycle without selecting any options just printing out

## input
- ✅ hotkey in insert mode for CTRL+arrows left and right to jump words, up and down to end/start of the line (already implemented)

## bugs
- ✅ variable expansion: `test.$VAR` and `result=$(cmd)` tokenize with spurious spaces (FIXED)
  - solution: made handleWord skip over expansions instead of treating $ as metacharacter
- ✅ backticks: not fully implemented, causes EmptyToken error (FIXED)
  - solution: added backtick skipping to handleWord
- ✅ single quotes: don't prevent variable expansion (FIXED)
  - solution: added DoubleQuotedString token type, single quotes create .String (no expansion)
- ✅ exit code preservation: semicolon-separated commands don't preserve `$?` (FIXED)
  - solution: update shell.last_exit_code in evaluateList
- arithmetic expansion: `$((expr))` not working
  - code exists in expand.zig but never triggers
  - affects while loop test that uses `i=$((i+1))`
  - needs debugging why evaluateArithmetic path isn't reached

## testing
- ✅ shellspec integration setup complete
- ✅ basic tests passing (12/12)
- ✅ advanced tests: 32/33 passing
- remaining failure: while loop test (requires arithmetic expansion)
- run tests: `make test` or `make test-verbose`
