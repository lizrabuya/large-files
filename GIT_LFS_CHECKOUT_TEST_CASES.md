# Git LFS Checkout — Test Case Scenarios

Test cases grouped by the steps in the command sequence described in `GIT_LFS_CHECKOUT.md`.

---

## Group 1: Feature Flag / Kill-switch

| # | Scenario | Assertion |
|---|----------|-----------|
| 1 | `BUILDKITE_GIT_LFS_ENABLED` absent | No `.git/lfs/` directory created; no LFS filter in `.git/config` |
| 2 | `BUILDKITE_GIT_LFS_ENABLED=false` | Same as above — no LFS state at all |
| 3 | `BUILDKITE_GIT_LFS_ENABLED=true` | LFS operations proceed (lfs filter in config, objects in store) |

**Test functions:** `test_lfs_disabled_absent`, `test_lfs_disabled_false`

---

## Group 2: Binary Probe

Probe command: `git lfs version` (exit 0 = binary present).

| # | Scenario | Assertion |
|---|----------|-----------|
| 4 | `git-lfs` binary not found (removed from PATH) | `git lfs version` exits non-zero → warn string emitted, build continues, no LFS state created |
| 5 | `git-lfs` binary present | `git lfs version` exits 0 → proceed to install |

**Test functions:** `test_binary_not_found`

---

## Group 3: Step 1 — `git lfs install --local`

Runs after repo is initialised (clone/fetch), before `git checkout`.

| # | Scenario | Assertion |
|---|----------|-----------|
| 6 | Local install ran | `filter.lfs.clean`, `filter.lfs.smudge`, `filter.lfs.process` all present in `.git/config` |
| 7 | Local install only (not global) | The above keys appear under `--local` config, not just `--global` |
| 8 | Hooks installed | `.git/hooks/{pre-push,post-checkout,post-commit,post-merge}` all contain "lfs" |

**Test functions:** `test_minimal_operation`, `test_fetch_include_exclude_checkout`

---

## Group 4: `GIT_LFS_SKIP_SMUDGE=1` during checkout

`GIT_LFS_SKIP_SMUDGE=1` is force-set in the process environment before `git checkout`, overriding any existing value (including a user-set `GIT_LFS_SKIP_SMUDGE=0`).

| # | Scenario | Assertion |
|---|----------|-----------|
| 9 | User had `GIT_LFS_SKIP_SMUDGE=0` in env | Post-checkout, LFS files on disk are still pointer files (confirming the override worked) |
| 10 | After checkout but before `git lfs checkout` | All `git lfs ls-files` entries show `-` marker (pointer only, not materialized) |

**Test functions:** `test_skip_smudge_checkout`, `test_skip_smudge_env_override`

---

## Group 5: Step 2a — `git lfs fetch` + `git lfs checkout`

Runs after `git checkout` and submodule operations. `git lfs checkout` uses the local cache only — no network call.

| # | Scenario | Assertion |
|---|----------|-----------|
| 11 | Default (no include/exclude) | All LFS objects for HEAD present in `.git/lfs/objects`; all `ls-files` entries show `*` after checkout |
| 12 | `BUILDKITE_GIT_LFS_FETCH_INCLUDE=assets/models/**` set | Objects under `assets/models/` are cached (`*`); objects outside are not fetched (`-`) |
| 13 | `BUILDKITE_GIT_LFS_FETCH_EXCLUDE=assets/legacy/**` set | Objects under `assets/legacy/` are absent (`-`); other objects are cached |
| 14 | Both include and exclude set | Included paths cached, excluded paths absent — both flags applied in one `fetch` call |
| 15 | Invalid glob in `BUILDKITE_GIT_LFS_FETCH_INCLUDE` | `git lfs fetch` exits non-zero → build fails |
| 16 | `git lfs checkout` uses only local cache | No network call made — succeeds even with an unreachable remote URL |
| 17 | `git lfs checkout` after fetch | All `ls-files` entries change from `-` to `*`; no pointer-format content in tracked files |

**Test functions:** `test_minimal_operation`, `test_fetch_include_exclude_checkout`, `test_invalid_glob_fails`, `test_checkout_local_cache`

---

## Group 6: Step 2b — Submodule LFS

Only runs when `BUILDKITE_GIT_SUBMODULES=true`. `GIT_LFS_SKIP_SMUDGE=1` is inherited by `git submodule update`, leaving LFS pointer files in each submodule. Each submodule is handled independently.

```
git -C <submodule-path> lfs install --local
git -C <submodule-path> lfs fetch [--include=<pattern>] [--exclude=<pattern>]
git -C <submodule-path> lfs checkout
```

| # | Scenario | Assertion |
|---|----------|-----------|
| 18 | `BUILDKITE_GIT_SUBMODULES=false` | No `git -C <path> lfs install` or checkout runs; no LFS filter config in any submodule |
| 19 | Single submodule with LFS files | `git -C <sub> lfs install --local` config present; all LFS files in submodule are materialized |
| 20 | Multiple submodules | Each submodule independently has LFS filter config and all objects materialized |
| 21 | Nested/recursive submodules | `git submodule foreach --recursive` reaches all levels; deepest submodule LFS files are also materialized |
| 22 | `GIT_LFS_SKIP_SMUDGE=1` inherited by submodule update | Before submodule LFS fetch+checkout, submodule LFS files are pointers (proving smudge was skipped) |
| 23 | Submodule with include/exclude | Same include/exclude env vars applied per submodule; only matching paths cached |

**Test functions:** `test_submodules_lfs_disabled`, `test_submodules_with_lfs`, `test_submodules_lfs_nested`

---

## Group 7: Step 3 — Prune

Runs in the pre-exit phase (while the checkout directory still exists). Default is disabled — recommended for ephemeral agents.

| # | Scenario | Assertion |
|---|----------|-----------|
| 24 | `BUILDKITE_GIT_LFS_PRUNE=false` (default) | Object count in `.git/lfs/objects` unchanged; all HEAD objects still present |
| 25 | `BUILDKITE_GIT_LFS_PRUNE=true` | `git lfs prune` exits 0; stale objects removed; current-HEAD objects still present |
| 26 | Prune does not remove objects needed by HEAD | After prune, `git lfs fsck --objects` passes and all HEAD files still materialize cleanly |

**Test functions:** `test_prune_default_disabled`, `test_git_lfs_prune`

---

## Group 8: Ordering / Sequencing

| # | Scenario | Assertion |
|---|----------|-----------|
| 27 | `git lfs install --local` runs before `git checkout` | `.git/config` has LFS filter before any pointer files are written |
| 28 | `git lfs fetch` runs before `git lfs checkout` | Objects in `.git/lfs/objects` exist before checkout is called; checkout succeeds without network |
| 29 | `git clean` runs after `git lfs checkout` | LFS files are not cleaned away — they survive the clean step as real content |
