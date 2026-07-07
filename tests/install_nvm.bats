#!/usr/bin/env bats
# Tests for install_nvm.sh with a fake ~/.nvm/nvm.sh (HOME is pointed at the
# sandbox). Proves the pinned node version is installed AND activated, and that
# a missing nvm installation fails instead of silently succeeding.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  common_setup
  export HOME="$SANDBOX"
  export NVM_MOCK_LOG="$SANDBOX/nvm.log"
}
teardown() { common_teardown; }

fake_nvm() {
  mkdir -p "$SANDBOX/.nvm"
  printf 'nvm(){ printf "nvm %%s\\n" "$*" >> "$NVM_MOCK_LOG"; }\n' > "$SANDBOX/.nvm/nvm.sh"
}

@test "installs and activates the pinned node version via nvm" {
  fake_nvm
  run sh "$REPO_ROOT/install_nvm.sh"
  [ "$status" -eq 0 ]
  run grep -Ec '^nvm (install|use) v[0-9]+\.[0-9]+\.[0-9]+$' "$NVM_MOCK_LOG"
  [ "$output" -eq 2 ]
}

@test "fails when nvm is not installed" {
  # 127 = "nvm: command not found" — the script must not mask it with exit 0
  run -127 sh "$REPO_ROOT/install_nvm.sh"
}
