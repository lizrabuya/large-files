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

# --- Logging Helpers -----------------------------------------------------------------
pass() { echo "  ✅ PASS: $1"; ((++PASS)); }
fail() { echo "  ❌ FAIL: $1"; ((++FAIL)); ERRORS+=("$1"); }
section() { echo; echo "━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# ---- test helpers ---------------------------------------------------------------
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

test_git_lfs_checkout() {
  # assume `git lfs checkout` was run successfully before this function is called

  POINTER_COUNT=0
  while IFS= read -r lfs_file; do
    if [[ -f "$lfs_file" ]]; then
      if LC_ALL=C head -1 "$lfs_file" 2>/dev/null | grep -qF "version https://git-lfs.github.com/spec/v1"; then
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

  if git config --global --get-regexp "filter.lfs" > /dev/null 2>&1; then
    pass "Global git config has LFS filter settings"
  else
    fail "Global git config missing LFS filter settings"
  fi
}

# --- git lfs checkout tests ------------------------------------------------------



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
    while IFS= read -r line; do
      marker="${line:11:1}"   # '*' = cached, '-' = pointer only
      lfs_file="${line:13}"
      if [[ "$marker" == "*" ]]; then
        pass "[$ref] LFS object cached: $lfs_file"
      else
        fail "[$ref] LFS object MISSING: $lfs_file"
      fi
    done < <(git lfs ls-files "$ref" 2>/dev/null)
  done

}

test_git_lfs_fetch_include_exclude() {
  # Assumes `git lfs fetch -I 'bin/**' -X 'src/**'` was run before this function.
  # Verifies:
  #   - LFS objects matching bin/**  are cached  (marker '*')
  #   - LFS objects matching src/**  are NOT cached (marker '-')
  #   - LFS objects matching test/** are NOT cached (marker '-')

  local included_path="bin/"
  local excluded_path=("src/" "test/")

  local included=0 excluded_cached=0 excluded_ok=0

  while IFS= read -r line; do
    local marker="${line:11:1}"   # '*' = cached, '-' = pointer only
    local lfs_file="${line:13}"

    # Determine which bucket this file belongs to
    local is_included=false
    local is_excluded=false

    [[ "$lfs_file" == ${included_path}* ]] && is_included=true
    for path in "${excluded_path[@]}"; do
      [[ "$lfs_file" == ${path}* ]] && is_excluded=true && break
    done

    if $is_included; then
      ((++included))
      if [[ "$marker" == "*" ]]; then
        pass "object cached: $lfs_file"
      else
        fail "object NOT cached (should have been fetched): $lfs_file"
      fi
    elif $is_excluded; then
      if [[ "$marker" == "-" ]]; then
        ((++excluded_ok))
        pass "excluded object correctly absent: $lfs_file"
      else
        ((++excluded_cached))
        fail "excluded object was fetched but should not have been: $lfs_file"
      fi
    fi
    # Files outside all patterns are not asserted either way
  done < <(git lfs ls-files 2>/dev/null)

  [[ "$included" -gt 0 ]] \
    || fail "No bin/** LFS files found — check that the repo has LFS-tracked files under bin/"

  [[ "$excluded_cached" -eq 0 ]] \
    && pass "No excluded (src/**/test/**) objects were fetched" \
    || fail "$excluded_cached excluded object(s) were unexpectedly fetched"
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



# ---- Group 1: LFS disabled (kill-switch) ----------------------------------------

test_lfs_not_initialized() {
  # Verifies no LFS state was created — called when BUILDKITE_GIT_LFS_ENABLED is absent or false
  if git config --local --get-regexp "filter.lfs" > /dev/null 2>&1; then
    fail "LFS filter found in local .git/config (should be absent when LFS is disabled)"
  else
    pass "No LFS filter in local .git/config (LFS correctly not initialized)"
  fi

  local lfs_obj_dir=".git/lfs/objects"
  local obj_count=0
  if [[ -d "$lfs_obj_dir" ]]; then
    obj_count=$(find "$lfs_obj_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
  fi

  if [[ "$obj_count" -eq 0 ]]; then
    pass "No LFS objects downloaded (LFS correctly disabled)"
  else
    fail "LFS objects found in store ($obj_count) — LFS should have been skipped"
  fi
}

# ---- Group 2: Binary probe -------------------------------------------------------

test_lfs_binary_probe() {
  # Verifies git-lfs is discoverable via git lfs version (the probe the agent runs)
  if git lfs version > /dev/null 2>&1; then
    local lfs_version
    lfs_version=$(git lfs version 2>/dev/null)
    pass "git-lfs binary found: $lfs_version"
  else
    fail "git lfs version exited non-zero — binary not found or broken"
  fi
}

test_lfs_binary_not_found_skips_lfs() {
  # Strips git-lfs from PATH and verifies: probe exits non-zero, install also fails.
  # Models the agent warn-and-continue path when the binary is absent.
  local lfs_path
  lfs_path=$(command -v git-lfs 2>/dev/null || true)
  if [[ -z "$lfs_path" ]]; then
    fail "git-lfs not in PATH — cannot set up binary-not-found simulation"
    return
  fi

  local lfs_dir
  lfs_dir=$(dirname "$lfs_path")
  local restricted_path
  restricted_path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^${lfs_dir}$" | paste -sd ':')

  if PATH="$restricted_path" git lfs version > /dev/null 2>&1; then
    fail "git-lfs still found in restricted PATH — PATH manipulation failed"
    return
  fi
  pass "git-lfs binary not found in restricted PATH (probe correctly returns non-zero)"

  if PATH="$restricted_path" git lfs install --local > /dev/null 2>&1; then
    fail "git lfs install --local succeeded without binary — unexpected"
  else
    pass "git lfs install --local correctly fails when binary is absent"
  fi
}

# ---- Group 4: GIT_LFS_SKIP_SMUDGE -----------------------------------------------

test_skip_smudge_produces_pointers() {
  # Clones with GIT_LFS_SKIP_SMUDGE=1 and verifies LFS-tracked files are pointer
  # files on disk, not materialized content — mirrors what the agent does before
  # running git lfs fetch + git lfs checkout.
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || true)
  if [[ -z "$remote_url" ]]; then
    fail "No remote 'origin' — cannot clone for skip-smudge verification"
    return
  fi

  local tracked_count
  tracked_count=$(git lfs ls-files -n 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$tracked_count" -eq 0 ]]; then
    pass "No LFS-tracked files in repo — skip-smudge test not applicable"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  if ! GIT_LFS_SKIP_SMUDGE=1 git clone --quiet "$remote_url" "$tmpdir/repo" 2>/dev/null; then
    fail "Clone with GIT_LFS_SKIP_SMUDGE=1 failed"
    return
  fi

  local pointer_count=0 non_pointer=0
  while IFS= read -r lfs_file; do
    local full_path="$tmpdir/repo/$lfs_file"
    if [[ -f "$full_path" ]] && LC_ALL=C head -1 "$full_path" 2>/dev/null | grep -qF "version https://git-lfs.github.com/spec/v1"; then
      ((++pointer_count))
    else
      ((++non_pointer))
      fail "Expected pointer but got real content: $lfs_file"
    fi
  done < <(git -C "$tmpdir/repo" lfs ls-files -n 2>/dev/null)

  [[ "$pointer_count" -gt 0 && "$non_pointer" -eq 0 ]] \
    && pass "GIT_LFS_SKIP_SMUDGE=1: all $pointer_count LFS file(s) are pointers after checkout" \
    || fail "GIT_LFS_SKIP_SMUDGE=1: $non_pointer file(s) were materialized — smudge suppression failed"
}

test_skip_smudge_overrides_existing_env() {
  # Verifies: GIT_LFS_SKIP_SMUDGE=1 force-overrides a pre-existing GIT_LFS_SKIP_SMUDGE=0.
  # Simulates a user who exported SKIP_SMUDGE=0; the agent must override it to 1.
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || true)
  if [[ -z "$remote_url" ]]; then
    fail "No remote 'origin' — cannot test skip-smudge override"
    return
  fi

  local tracked_count
  tracked_count=$(git lfs ls-files -n 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$tracked_count" -eq 0 ]]; then
    pass "No LFS-tracked files — skip-smudge override test not applicable"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  # Outer env has SKIP_SMUDGE=0; inner command force-sets to 1 (models agent behavior)
  if ! GIT_LFS_SKIP_SMUDGE=0 bash -c "GIT_LFS_SKIP_SMUDGE=1 git clone --quiet '$remote_url' '$tmpdir/repo'" 2>/dev/null; then
    fail "Clone failed during skip-smudge override test"
    return
  fi

  local pointer_count=0
  while IFS= read -r lfs_file; do
    if LC_ALL=C head -1 "$tmpdir/repo/$lfs_file" 2>/dev/null | grep -qF "version https://git-lfs.github.com/spec/v1"; then
      ((++pointer_count))
    fi
  done < <(git -C "$tmpdir/repo" lfs ls-files -n 2>/dev/null)

  [[ "$pointer_count" -gt 0 ]] \
    && pass "GIT_LFS_SKIP_SMUDGE=1 overrides pre-existing =0: $pointer_count pointer file(s) on disk" \
    || fail "Override failed — files were smudged despite GIT_LFS_SKIP_SMUDGE=1 being set"
}

# ---- Group 5: Fetch + Checkout ---------------------------------------------------

test_invalid_glob_fetch_fails() {
  # An invalid glob in --include must cause git lfs fetch to exit non-zero (fail the build).
  local invalid_pattern='[invalid-glob'
  local exit_code=0
  git lfs fetch --include="$invalid_pattern" > /dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    pass "git lfs fetch correctly exits non-zero for invalid glob: $invalid_pattern"
  else
    fail "git lfs fetch should have failed with invalid glob '$invalid_pattern' but exited 0"
  fi
}

test_checkout_uses_local_cache_only() {
  # git lfs checkout must succeed using only the local object store — no network call.
  # Verified by temporarily pointing origin to an unreachable URL.
  local obj_count
  obj_count=$(find ".git/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$obj_count" -eq 0 ]]; then
    fail "LFS object store is empty — cannot verify local-cache-only checkout"
    return
  fi

  local original_url
  original_url=$(git remote get-url origin 2>/dev/null || true)

  local checkout_exit=0
  if [[ -n "$original_url" ]]; then
    git remote set-url origin "https://lfs-no-network-test.invalid/repo.git"
    git lfs checkout > /dev/null 2>&1 || checkout_exit=$?
    git remote set-url origin "$original_url"
  else
    git lfs checkout > /dev/null 2>&1 || checkout_exit=$?
  fi

  if [[ "$checkout_exit" -eq 0 ]]; then
    pass "git lfs checkout succeeded with unreachable remote — confirmed local-cache-only"
  else
    fail "git lfs checkout failed with unreachable remote — may require network (exit: $checkout_exit)"
  fi
}

# ---- Group 6: Submodule LFS ------------------------------------------------------

test_submodules_no_lfs_state() {
  # When BUILDKITE_GIT_SUBMODULES != true, no submodule should have LFS filter config.
  local sub_count=0 lfs_state_found=0

  while IFS= read -r sub_path; do
    [[ -z "$sub_path" ]] && continue
    ((++sub_count))
    if git -C "$sub_path" config --local --get-regexp "filter.lfs" > /dev/null 2>&1; then
      fail "Submodule at $sub_path has LFS filter config (should be absent — submodules disabled)"
      ((++lfs_state_found))
    fi
  done < <(git submodule foreach --quiet --recursive pwd 2>/dev/null || true)

  if [[ "$sub_count" -eq 0 ]]; then
    pass "No submodules present"
  elif [[ "$lfs_state_found" -eq 0 ]]; then
    pass "No submodule has LFS state — correctly skipped when submodules disabled"
  fi
}

test_submodule_lfs_install_local() {
  # Each submodule must have LFS filter config written by git -C <path> lfs install --local.
  local sub_count=0 missing=0

  while IFS= read -r sub_path; do
    [[ -z "$sub_path" ]] && continue
    ((++sub_count))
    if git -C "$sub_path" config --local --get-regexp "filter.lfs" > /dev/null 2>&1; then
      pass "LFS filter config present in submodule: $sub_path"
    else
      fail "LFS filter config missing in submodule: $sub_path"
      ((++missing))
    fi
  done < <(git submodule foreach --quiet --recursive pwd 2>/dev/null)

  if [[ "$sub_count" -eq 0 ]]; then
    pass "No submodules found — submodule LFS install test not applicable"
  else
    [[ "$missing" -eq 0 ]] && pass "All $sub_count submodule(s) have LFS filter config"
  fi
}

test_submodule_lfs_files_materialized() {
  # All LFS-tracked files in every submodule must be real content, not pointer files.
  local sub_count=0 total_pointers=0

  while IFS= read -r sub_path; do
    [[ -z "$sub_path" ]] && continue
    ((++sub_count))
    local sub_pointers=0

    while IFS= read -r lfs_file; do
      local full_path="$sub_path/$lfs_file"
      if [[ -f "$full_path" ]] && LC_ALL=C head -1 "$full_path" 2>/dev/null | grep -qF "version https://git-lfs.github.com/spec/v1"; then
        fail "Submodule LFS file still a pointer: $full_path"
        ((++sub_pointers))
        ((++total_pointers))
      else
        pass "Submodule LFS file materialized: $full_path"
      fi
    done < <(git -C "$sub_path" lfs ls-files -n 2>/dev/null)

    [[ "$sub_pointers" -eq 0 ]] && pass "All LFS files materialized in submodule: $sub_path"
  done < <(git submodule foreach --quiet --recursive pwd 2>/dev/null)

  if [[ "$sub_count" -eq 0 ]]; then
    pass "No submodules found — submodule materialization test not applicable"
  fi
}

test_submodule_lfs_recursive_enumeration() {
  # git submodule foreach --quiet --recursive pwd must enumerate every nesting level;
  # each enumerated submodule with LFS files must have LFS config present.
  local sub_paths=()
  while IFS= read -r sub_path; do
    [[ -n "$sub_path" ]] && sub_paths+=("$sub_path")
  done < <(git submodule foreach --quiet --recursive pwd 2>/dev/null || true)

  if [[ "${#sub_paths[@]}" -eq 0 ]]; then
    pass "No submodules found — recursive enumeration test not applicable"
    return
  fi

  pass "git submodule foreach --recursive enumerated ${#sub_paths[@]} path(s)"

  local max_depth=0
  for sub_path in "${sub_paths[@]}"; do
    local depth
    depth=$(awk -F'/' '{print NF-1}' <<< "$sub_path")
    [[ "$depth" -gt "$max_depth" ]] && max_depth="$depth"
  done
  echo "  Max submodule nesting depth: $max_depth"

  [[ "$max_depth" -gt 1 ]] \
    && pass "Nested submodules detected (depth: $max_depth) — recursive enumeration is meaningful" \
    || pass "Single-level submodules only (depth: $max_depth)"

  for sub_path in "${sub_paths[@]}"; do
    local lfs_file_count
    lfs_file_count=$(git -C "$sub_path" lfs ls-files -n 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$lfs_file_count" -gt 0 ]]; then
      if git -C "$sub_path" config --local --get-regexp "filter.lfs" > /dev/null 2>&1; then
        pass "LFS config present in nested submodule: $sub_path"
      else
        fail "LFS config missing in nested submodule: $sub_path"
      fi
    fi
  done
}

# ---- Group 7: Prune (default off) ------------------------------------------------

test_prune_skipped_objects_intact() {
  # When BUILDKITE_GIT_LFS_PRUNE is absent/false, git lfs prune must NOT have run.
  # We can't observe a non-event directly; instead verify all HEAD-referenced LFS
  # objects are still present — prune incorrectly running would remove them.
  local obj_count
  obj_count=$(find ".git/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  LFS objects in store: $obj_count"

  if [[ "$obj_count" -eq 0 ]]; then
    fail "LFS object store is empty — cannot verify prune was correctly skipped"
    return
  fi

  local missing=0
  while IFS= read -r line; do
    local marker="${line:11:1}"
    local lfs_file="${line:13}"
    if [[ "$marker" == "-" ]]; then
      fail "LFS object absent from store (may have been pruned prematurely): $lfs_file"
      ((++missing))
    fi
  done < <(git lfs ls-files 2>/dev/null)

  [[ "$missing" -eq 0 ]] \
    && pass "All HEAD-referenced LFS objects present — prune correctly not run" \
    || fail "$missing HEAD object(s) missing — prune may have run when disabled"

  integrity_check_lfs_objects
}

# --- individual test cases ------------------------------------------------------

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

test_fetch_include_exclude_checkout() {
  cat <<'EOF'
steps:
  - command: "build.sh"
    checkout:
      lfs:
        prune: false                   # optional. default: false
        fetch:
          include: "assets/models/**"  # optional. passed as --include to git lfs fetch
          exclude: "assets/legacy/**"  # optional. passed as --exclude to git lfs fetch
EOF
  echo
  test_git_lfs_install_local
  test_git_lfs_config_has_lfs_filter
  test_git_lfs_fetch_include_exclude
  test_git_lfs_checkout
}

test_git_lfs_prune() {
  # Snapshot which objects are currently cached before pruning
  local cached_before
  cached_before=$(git lfs ls-files 2>/dev/null | awk '/ \* / {print $NF}')

  local obj_count_before
  obj_count_before=$(find ".git/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')

  if git lfs prune > /dev/null 2>&1; then
    pass "git lfs prune completed successfully"
  else
    fail "git lfs prune failed"
    return
  fi

  local obj_count_after
  obj_count_after=$(find ".git/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')
  local pruned=$(( obj_count_before - obj_count_after ))
  echo "  objects before: $obj_count_before  after: $obj_count_after  pruned: $pruned"

  # Verify no previously-cached object was incorrectly removed
  local incorrectly_pruned=0
  while IFS= read -r line; do
    local marker="${line:11:1}"
    local lfs_file="${line:13}"
    if [[ "$marker" == "-" ]] && echo "$cached_before" | grep -qxF "$lfs_file"; then
      fail "Object was cached before prune but removed: $lfs_file"
      ((++incorrectly_pruned))
    fi
  done < <(git lfs ls-files 2>/dev/null)

  [[ "$incorrectly_pruned" -eq 0 ]] \
    && pass "No required objects were removed by prune" \
    || fail "$incorrectly_pruned required object(s) were incorrectly pruned"

  integrity_check_lfs_objects
}

test_lfs_disabled_absent() {
  cat <<'EOF'
Scenario: BUILDKITE_GIT_LFS_ENABLED absent
  Expected: no LFS operations, no LFS state in repo
EOF
  echo
  test_lfs_not_initialized
}

test_lfs_disabled_false() {
  cat <<'EOF'
Scenario: BUILDKITE_GIT_LFS_ENABLED=false
  Expected: no LFS operations, no LFS state in repo
EOF
  echo
  test_lfs_not_initialized
}

test_binary_not_found() {
  cat <<'EOF'
Scenario: git-lfs binary absent from PATH
  Expected: probe exits non-zero, install fails, build continues without LFS
EOF
  echo
  test_lfs_binary_probe
  test_lfs_binary_not_found_skips_lfs
}

test_skip_smudge_checkout() {
  cat <<'EOF'
Scenario: GIT_LFS_SKIP_SMUDGE=1 force-set before git checkout
  Expected: LFS-tracked files written as pointer files, not materialized content
EOF
  echo
  test_skip_smudge_produces_pointers
}

test_skip_smudge_env_override() {
  cat <<'EOF'
Scenario: GIT_LFS_SKIP_SMUDGE=1 overrides a pre-existing GIT_LFS_SKIP_SMUDGE=0
  Expected: pointer files on disk even when the user had exported SKIP_SMUDGE=0
EOF
  echo
  test_skip_smudge_overrides_existing_env
}

test_invalid_glob_fails() {
  cat <<'EOF'
Scenario: invalid glob in BUILDKITE_GIT_LFS_FETCH_INCLUDE / FETCH_EXCLUDE
  Expected: git lfs fetch exits non-zero, failing the build
EOF
  echo
  test_invalid_glob_fetch_fails
}

test_checkout_local_cache() {
  cat <<'EOF'
Scenario: git lfs checkout uses local object store only — no network call
  Expected: checkout succeeds even with an unreachable remote URL
EOF
  echo
  test_checkout_uses_local_cache_only
}

test_submodules_lfs_disabled() {
  cat <<'EOF'
Scenario: BUILDKITE_GIT_SUBMODULES=false — submodule LFS operations skipped
  Expected: no submodule has LFS filter config
EOF
  echo
  test_submodules_no_lfs_state
}

test_submodules_with_lfs() {
  cat <<'EOF'
Scenario: BUILDKITE_GIT_SUBMODULES=true — each submodule gets lfs install + fetch + checkout
  Expected: all submodules have LFS filter config and fully materialized files
EOF
  echo
  test_submodule_lfs_install_local
  test_submodule_lfs_files_materialized
}

test_submodules_lfs_nested() {
  cat <<'EOF'
Scenario: nested submodules — git submodule foreach --recursive enumerates all levels
  Expected: LFS config and materialized files at every nesting depth
EOF
  echo
  test_submodule_lfs_recursive_enumeration
}

test_prune_default_disabled() {
  cat <<'EOF'
Scenario: BUILDKITE_GIT_LFS_PRUNE absent/false — git lfs prune must not run
  Expected: all HEAD LFS objects remain in store after pre-exit phase
EOF
  echo
  test_prune_skipped_objects_intact
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
