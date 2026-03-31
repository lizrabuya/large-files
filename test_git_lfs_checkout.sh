#!/usr/bin/env bash
# =============================================================================
# test_git_lfs_checkout.sh
# Tests to validate git lfs operations after a Buildkite-style git clone
# =============================================================================

set -euo pipefail

BUILD_DIR="${1:-$(pwd)}"
TEST_FN="${2:-}"

PASS=0
FAIL=0
ERRORS=()

# --- Helpers -----------------------------------------------------------------
pass() { echo "  ✅ PASS: $1"; ((++PASS)); }
fail() { echo "  ❌ FAIL: $1"; ((++FAIL)); ERRORS+=("$1"); }
section() { echo; echo "━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# --- git lfs checkout tests ------------------------------------------------------
test_git_lfs_install_local() {
  for hook in pre-push post-checkout post-commit post-merge; do
    HOOK_FILE=".git/hooks/$hook"
    if [[ -f "$HOOK_FILE" ]] && grep -q "lfs" "$HOOK_FILE"; then
      pass "LFS hook installed: $hook"
    else
      fail "LFS hook missing or not LFS-related: $hook"
    fi
  done
}

test_git_lfs_config_has_lfs_filter() {
  if git config --local --get-regexp "filter.lfs" > /dev/null 2>&1; then
    pass "Local git config has LFS filter settings"
  else
    fail "Local git config missing LFS filter settings"
  fi
}

test_git_lfs_fetch() {
  local args="${1:-}"
  if git lfs fetch $args > /dev/null 2>&1; then
    pass "git lfs fetch${args:+ $args} completed successfully"
  else
    fail "git lfs fetch${args:+ $args} failed"
  fi
}

test_git_lfs_checkout() {
  if git lfs checkout > /dev/null 2>&1; then
    pass "git lfs checkout completed successfully"
  else
    fail "git lfs checkout failed"
  fi

  # Check for any remaining LFS pointer files (simplified check)
  if find . -type f -name "*.lfs" | grep -q .; then
    fail "LFS pointer files remain after checkout"
  else
    pass "No LFS pointer files remain after checkout"
  fi
}

test_minimal_operation() {
  cat <<'EOF'
steps:
  - command: ...
    checkout:
      lfs: {}
EOF
  echo

  test_git_lfs_install_local
  test_git_lfs_config_has_lfs_filter
  test_git_lfs_fetch
  test_git_lfs_checkout
}

test_fetch_checkout_get_all() {
  cat <<'EOF'
steps:
  - command: ...
    checkout:
      lfs:
        fetch: "--all"
EOF
  echo

  test_git_lfs_install_local
  test_git_lfs_config_has_lfs_filter
  test_git_lfs_fetch "--all"
  test_git_lfs_checkout
}


cd "$BUILD_DIR"

if [[ -n "$TEST_FN" ]]; then
  if declare -f "$TEST_FN" > /dev/null; then
    section "$TEST_FN"
    "$TEST_FN"
  else
    echo "Error: unknown function '$TEST_FN'" >&2
    exit 1
  fi
else
  echo "No specific test function provided, exiting with failure."
  exit 1
fi

# =============================================================================
# SUMMARY
# =============================================================================
section "Test Summary"
echo "  Total passed : $PASS"
echo "  Total failed : $FAIL"

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  echo
  echo "  Failed tests:"
  for e in "${ERRORS[@]}"; do
    echo "    - $e"
  done
  echo
  exit 1
else
  echo
  echo "  ✅ All tests passed."
  exit 0
fi
