#!/usr/bin/env bash
# =============================================================================
# test_git_lfs_checkout.sh
# Tests to validate git lfs operations after a Buildkite-style git clone
# =============================================================================

set -euo pipefail

BUILD_DIR="${1:-$(pwd)}"

PASS=0
FAIL=0
ERRORS=()

# --- Helpers -----------------------------------------------------------------
pass() { echo "  ✅ PASS: $1"; ((++PASS)); }
fail() { echo "  ❌ FAIL: $1"; ((++FAIL)); ERRORS+=("$1"); }
section() { echo; echo "━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

cd "$BUILD_DIR"

# =============================================================================
# 1. GIT LFS INSTALL — validate `git lfs install --local`
# =============================================================================
section "1. git lfs install --local"

# 1.1 LFS hooks are installed
for hook in pre-push post-checkout post-commit post-merge; do
  HOOK_FILE=".git/hooks/$hook"
  if [[ -f "$HOOK_FILE" ]] && grep -q "lfs" "$HOOK_FILE"; then
    pass "LFS hook installed: $hook"
  else
    fail "LFS hook missing or not LFS-related: $hook"
  fi
done

# 1.2 Local git config has lfs filter settings
for key in "filter.lfs.clean" "filter.lfs.smudge" "filter.lfs.process" "filter.lfs.required"; do
  VALUE=$(git config --local "$key" 2>/dev/null || echo "")
  [[ -n "$VALUE" ]] \
    && pass "Local git config has: $key = $VALUE" \
    || fail "Local git config missing key: $key"
done

# =============================================================================
# 2. GIT LFS FETCH — validate `git lfs fetch`
# =============================================================================
section "2. git lfs fetch"

# 2.1 .git/lfs/objects directory exists and has content
LFS_OBJ_DIR=".git/lfs/objects"
if [[ -d "$LFS_OBJ_DIR" ]]; then
  OBJ_COUNT=$(find "$LFS_OBJ_DIR" -type f | wc -l)
  [[ "$OBJ_COUNT" -gt 0 ]] \
    && pass "LFS objects directory has $OBJ_COUNT object(s)" \
    || fail "LFS objects directory exists but is empty — fetch may have failed"
else
  fail "LFS objects directory missing: $LFS_OBJ_DIR"
fi

# 2.2 Every tracked LFS pointer has a corresponding cached object on disk
while IFS= read -r lfs_file; do
  OID=$(git show HEAD:"$lfs_file" 2>/dev/null | grep "^oid sha256:" | awk '{print $2}' | cut -d: -f2)
  if [[ -z "$OID" ]]; then
    fail "Could not read LFS pointer OID for: $lfs_file"
    continue
  fi
  OBJ_PATH=".git/lfs/objects/${OID:0:2}/${OID:2:2}/$OID"
  [[ -f "$OBJ_PATH" ]] \
    && pass "LFS object cached for: $lfs_file (oid: ${OID:0:12}...)" \
    || fail "LFS object MISSING for: $lfs_file (oid: ${OID:0:12}...)"
done < <(git lfs ls-files -n 2>/dev/null)

# =============================================================================
# 3. GIT LFS CHECKOUT — validate `git lfs checkout`
# =============================================================================
section "3. git lfs checkout"

# 3.1 No LFS pointer files remain in the working tree (all smudged)
POINTER_COUNT=0
while IFS= read -r lfs_file; do
  if [[ -f "$lfs_file" ]]; then
    FIRST_LINE=$(head -1 "$lfs_file" 2>/dev/null || echo "")
    if [[ "$FIRST_LINE" == "version https://git-lfs.github.com/spec/v1" ]]; then
      fail "File is still an LFS pointer (not checked out): $lfs_file"
      ((++POINTER_COUNT))
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
echo "  Running: git lfs fsck ..."
FSCK_OUTPUT=$(git lfs fsck 2>&1 || true)
if echo "$FSCK_OUTPUT" | grep -qi "error\|corrupt\|invalid"; then
  fail "git lfs fsck reported errors: $FSCK_OUTPUT"
else
  pass "git lfs fsck passed with no errors"
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
