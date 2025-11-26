#shellcheck shell=sh

Describe 'zish advanced functionality'
  zish() {
    ./zig-out/bin/zish -c "$1"
  }

  Describe 'logical operators'
    It 'handles && (and) operator'
      When call zish "true && echo success"
      The output should include "success"
    End

    It 'skips second command with && on failure'
      When call zish "false && echo should_not_appear"
      The status should eq 1
      The output should not include "should_not_appear"
    End

    It 'handles || (or) operator'
      When call zish "false || echo fallback"
      The output should include "fallback"
    End

    It 'skips second command with || on success'
      When call zish "true || echo should_not_appear"
      The output should not include "should_not_appear"
    End
  End

  Describe 'control flow'
    It 'handles if-then-fi'
      When call zish "if true; then echo works; fi"
      The output should include "works"
    End

    It 'handles if-then-else-fi'
      When call zish "if false; then echo bad; else echo good; fi"
      The output should include "good"
      The output should not include "bad"
    End

    It 'handles while loop'
      When call zish 'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done'
      The output should include "0"
      The output should include "1"
      The output should include "2"
    End

    It 'handles for loop'
      When call zish 'for i in a b c; do echo $i; done'
      The output should include "a"
      The output should include "b"
      The output should include "c"
    End
  End

  Describe 'command substitution'
    It 'handles $(command) syntax'
      When call zish 'echo result=$(echo nested)'
      The output should include "result=nested"
    End

    It 'handles backtick syntax'
      When call zish 'echo result=`echo nested`'
      The output should include "result=nested"
    End
  End

  Describe 'quoting'
    It 'handles single quotes (no expansion)'
      When call zish "echo '\$USER'"
      The output should include '$USER'
    End

    It 'handles double quotes (with expansion)'
      When call zish 'echo "$USER"'
      The output should include "$USER"
    End

    It 'handles escaped characters'
      When call zish 'echo "hello\nworld"'
      The output should include "hello"
    End
  End

  Describe 'glob patterns'
    It 'expands * wildcard'
      When call zish "echo *.md"
      The output should include ".md"
    End

    It 'expands ? wildcard'
      When call zish "echo ????.md"
      The output should include ".md"
    End
  End

  Describe 'environment'
    It 'sets environment variables'
      When call zish "export TEST_VAR=hello && echo \$TEST_VAR"
      The output should include "hello"
    End

    It 'unsets variables'
      When call zish "export TEST_VAR=hello && unset TEST_VAR && echo \$TEST_VAR"
      The output should not include "hello"
    End
  End

  Describe 'exit codes'
    It 'returns 0 for successful commands'
      When call zish "true"
      The status should eq 0
    End

    It 'returns non-zero for failed commands'
      When call zish "false"
      The status should not eq 0
    End

    It 'preserves exit code in $?'
      When call zish "false; echo \$?"
      The output should include "1"
    End
  End

  Describe 'comments'
    It 'ignores # comments'
      When call zish "echo before # this is a comment"
      The output should include "before"
      The output should not include "comment"
    End
  End
End
