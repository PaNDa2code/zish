#shellcheck shell=sh

Describe 'zish basic functionality'
  zish() {
    ./zig-out/bin/zish -c "$1"
  }

  Describe 'echo command'
    It 'outputs simple text'
      When call zish "echo hello world"
      The output should include "hello world"
    End

    It 'handles IP addresses correctly'
      When call zish "echo 1.1.1.1"
      The output should include "1.1.1.1"
      The output should not include "1 .1.1.1"
    End

    It 'handles decimals'
      When call zish "echo 3.14159"
      The output should include "3.14159"
    End

    It 'handles filenames with dots'
      When call zish "echo test.tar.gz"
      The output should include "test.tar.gz"
    End
  End

  Describe 'variable expansion'
    It 'expands $USER'
      When call zish 'echo $USER'
      The output should include "$USER"
    End

    It 'expands $? (exit code)'
      When call zish 'echo $?'
      The output should include "0"
    End

    It 'expands $HOME'
      When call zish 'echo $HOME'
      The output should include "$HOME"
    End

    It 'handles variable with suffix like $USER.txt'
      When call zish 'echo $USER.txt'
      The output should include "${USER}.txt"
      The output should not include " .txt"
    End
  End

  Describe 'pipes'
    It 'handles simple pipes'
      When call zish "echo test | cat"
      The output should include "test"
    End
  End

  Describe 'redirects'
    It 'handles stderr redirection 2>&1'
      When call zish "ls nonexistent 2>&1"
      The status should not eq 0
      The stderr should include "nonexistent"
    End
  End

  Describe 'builtins'
    It 'handles pwd command'
      When call zish "pwd"
      The status should eq 0
      The output should include "/"
    End

    It 'handles exit command'
      When call zish "exit"
      The status should eq 0
    End
  End
End
