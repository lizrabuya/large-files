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

test_git_lfs_install_global() {
  local global_hooks_dir
  global_hooks_dir="$(git config --global core.hooksPath 2>/dev/null || echo "${XDG_CONFIG_HOME:-$HOME/.config}/git/hooks")"

  for hook in pre-push post-checkout post-commit post-merge; do
    HOOK_FILE="$global_hooks_dir/$hook"
    if [[ -f "$HOOK_FILE" ]] && grep -q "lfs" "$HOOK_FILE"; then
      pass "Global LFS hook installed: $hook"
    else
      fail "Global LFS hook missing or not LFS-related: $hook ($HOOK_FILE)"
    fi
  done

  if git config --global --get-regexp "filter.lfs" > /dev/null 2>&1; then
    pass "Global git config has LFS filter settings"
  else
    fail "Global git config missing LFS filter settings"
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

check_lfs_objects_store_is_non_empty() {
  local lfs_store=".git/lfs/objects"
  if [[ ! -d "$lfs_store" ]]; then
    fail "LFS object store directory missing: $lfs_store"
    return
  fi
  local obj_count
  obj_count=$(find "$lfs_store" -type f | wc -l | tr -d ' ')
  if [[ "$obj_count" -eq 0 ]]; then
    fail "LFS object store is empty after fetch --all"
  else
    pass "LFS object store contains $obj_count object(s)"
  fi
}

integrity_check_lfs_objects() {
  if git lfs fsck --objects > /dev/null 2>&1; then
    pass "git lfs fsck --objects passed with no integrity issues"
  else
    fail "git lfs fsck --objects reported integrity issues"
  fi
}

test_git_lfs_fetch_recent() {
  # Configurable LFS recent fetch window (mirrors git-lfs defaults)
  RECENT_REFS_DAYS=$(git config lfs.fetchrecentrefsdays 2>/dev/null || echo 7)
  RECENT_COMMITS_DAYS=$(git config lfs.fetchrecentcommitsdays 2>/dev/null || echo 0)
  echo "  lfs.fetchrecentrefsdays    : $RECENT_REFS_DAYS"
  echo "  lfs.fetchrecentcommitsdays : $RECENT_COMMITS_DAYS"

  # 2.1 .git/lfs/objects directory exists and has content
  LFS_OBJ_DIR=".git/lfs/objects"
  if [[ -d "$LFS_OBJ_DIR" ]]; then
    OBJ_COUNT=$(find "$LFS_OBJ_DIR" -type f | wc -l)
    [[ "$OBJ_COUNT" -gt 0 ]] \
      && pass "LFS objects directory has $OBJ_COUNT object(s)" \
      || fail "LFS objects directory exists but is empty — fetch --recent may have fetched nothing"
  else
    fail "LFS objects directory missing: $LFS_OBJ_DIR"
  fi

  # 2.2 Collect recent refs within the fetchrecentrefsdays window
  RECENT_REFS=()
  while IFS= read -r ref; do
    REF_DATE=$(git log -1 --format="%ct" "$ref" 2>/dev/null || echo 0)
    CUTOFF=$(date -d "-${RECENT_REFS_DAYS} days" +%s 2>/dev/null \
      || date -v "-${RECENT_REFS_DAYS}d" +%s 2>/dev/null || echo 0)  # Linux / macOS
    [[ "$REF_DATE" -ge "$CUTOFF" ]] && RECENT_REFS+=("$ref")
  done < <(git for-each-ref --format="%(refname:short)" refs/remotes/origin/ 2>/dev/null)

  if [[ "${#RECENT_REFS[@]}" -eq 0 ]]; then
    # Fall back to HEAD if no remote refs qualify (e.g. shallow/mirror clone)
    RECENT_REFS=("HEAD")
    echo "  No remote refs within window — falling back to HEAD"
  else
    echo "  Recent refs in window (${RECENT_REFS_DAYS}d): ${RECENT_REFS[*]}"
  fi

  # 2.3 Every LFS pointer on each recent ref has a cached object on disk
  for ref in "${RECENT_REFS[@]}"; do
    while IFS= read -r lfs_file; do
      OID=$(git show "${ref}:${lfs_file}" 2>/dev/null \
        | grep "^oid sha256:" | awk '{print $2}' | cut -d: -f2)
      if [[ -z "$OID" ]]; then
        fail "[$ref] Could not read LFS pointer OID for: $lfs_file"
        continue
      fi
      OBJ_PATH=".git/lfs/objects/${OID:0:2}/${OID:2:2}/$OID"
      [[ -f "$OBJ_PATH" ]] \
        && pass "[$ref] LFS object cached for: $lfs_file (oid: ${OID:0:12}...)" \
        || fail "[$ref] LFS object MISSING for: $lfs_file (oid: ${OID:0:12}...)"
    done < <(git lfs ls-files -n --ref "$ref" 2>/dev/null)
  done

}

test_git_lfs_fetch_all() {
  # 1. assume `git lfs fetch --all` was run successfully before this function is called
  # 2. LFS object store must be non-empty
  check_lfs_objects_store_is_non_empty

  # 3. Every tracked LFS pointer must have its object present in the store
  local missing=0
  while IFS= read -r line; do
    # git lfs ls-files output: "<oid> - <path>" (dash = not in store, asterisk = present)
    if [[ "$line" == *" - "* ]]; then
      local fname="${line##* - }"
      fail "LFS object missing from store after fetch --all: $fname"
      ((++missing))
    fi
  done < <(git lfs ls-files 2>/dev/null)
  if [[ "$missing" -eq 0 ]]; then
    pass "All tracked LFS objects are present in the store"
  fi

  # 4. Integrity check on stored objects
  integrity_check_lfs_objects
}

test_git_lfs_checkout() {
  # assume `git lfs checkout` was run successfully before this function is called

  POINTER_COUNT=0
  while IFS= read -r lfs_file; do
    if [[ -f "$lfs_file" ]]; then
      FIRST_LINE=$(head -1 "$lfs_file" 2>/dev/null || echo "")
      if [[ "$FIRST_LINE" == "version https://git-lfs.github.com/spec/v1" ]]; then
        fail "File is still an LFS pointer (not checked out): $lfs_file"
        ((POINTER_COUNT++))
      else
        FILE_SIZE=$(stat -f%z "$lfs_file" 2>/dev/null || stat -c%s "$lfs_file" 2>/dev/null || echo 0)
        pass "File checked out (${FILE_SIZE} bytes): $lfs_file"
      fi
    else
      fail "Expected LFS file does not exist: $lfs_file"
    fi
  done < <(git lfs ls-files -n 2>/dev/null)

  [[ "$POINTER_COUNT" -eq 0 ]] \
    && pass "All LFS files fully checked out (no residual pointers)" \
    || fail "$POINTER_COUNT file(s) still contain LFS pointers"

  # 3.2 git lfs fsck — object integrity check
  integrity_check_lfs_objects

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
  test_git_lfs_fetch_all
  test_git_lfs_checkout
}

test_fetch_recent() {
  cat <<'EOF'
steps:
  - command: ...
    checkout:
      lfs:
        fetch: "--recent"
EOF
  echo

  test_git_lfs_install_local
  test_git_lfs_config_has_lfs_filter
  test_git_lfs_fetch "--recent"
  test_git_lfs_checkout
}

test_global_install() {
  cat <<'EOF'
steps:
  - command: ...
    checkout:
      lfs:
        install_scope: global
EOF
  echo

  test_git_lfs_install_global
  test_git_lfs_fetch
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
