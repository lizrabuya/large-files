# Git LFS Checkout Analysis

Research notes for https://linear.app/buildkite/issue/SUP-6524/research-git-lfs-git-behavior-and-implementation-strategy.

---

## Git LFS Checkout Behavior

### 1. `git lfs install --local` vs `git lfs install` (global)

`git lfs install` (no flag) writes filter config (`filter.lfs.clean`, `filter.lfs.smudge`,
`filter.lfs.process`, `filter.lfs.required`) and installs hooks into `~/.gitconfig` and the global
hooks directory. Persists across all repos for the user.

`git lfs install --local` writes the same config to `.git/config` and installs hooks into
`.git/hooks/`. Scoped entirely to that repository; no effect on other repos on the same host.

**Use `--local` in the agent** because:
- Agents may run as a shared system user — touching global config risks polluting other
  builds/repos on the same host.
- Must be run *after* the repo is initialized (post-clone/init) since it requires a `.git/`
  directory to exist.

---

### 2. `git lfs pull` when no LFS-tracked files exist

**It is a no-op; it does not fail.**

`git lfs pull` = `git lfs fetch` + `git lfs checkout`. Both commands inspect the current HEAD for
LFS pointer blobs. If no files in HEAD are LFS pointers, the batch API is never contacted, no
objects are downloaded, and both commands exit 0.

**Caveat**: if the LFS remote endpoint is unreachable (network issue, auth failure), behavior
depends on the version:
- Older git-lfs (< 2.x): may attempt contact even with nothing to fetch.
- Modern git-lfs (2.x+): skips the batch request entirely when the pointer list is empty.

`git lfs pull` can be called unconditionally after checkout and is safe on repos with no LFS usage.

---

### 3. Interaction with shallow clones (`checkout.depth`)

**LFS is unaffected by clone depth.**

Git LFS objects live outside the git object database — they are fetched from the LFS batch API
endpoint (`{remote}/info/lfs`), not reconstructed from git history. `--depth=1` (or any depth)
only limits how many commits of git history are fetched; LFS objects for the checked-out working
tree are fetched independently.

Concretely:
- `git clone --depth=1 <repo>` → LFS pointer files are present in HEAD tree (they are tiny text
  blobs, always fetched as part of normal tree checkout).
- `git lfs pull` → fetches binary objects for those pointers from the LFS server. Works
  identically to a full-depth clone.

No special handling is needed when `checkout.depth` / `BUILDKITE_GIT_CLONE_FLAGS` includes
`--depth`.

---

### 4. Interaction with partial clones and sparse checkout

#### Partial clones (`git clone --filter=blob:none`)

The filter skips fetching blobs from the git server during clone. LFS pointer files are small
(< 200 bytes) text blobs — git fetches them lazily on demand, so they are effectively always
available. `git lfs pull` then fetches the actual binary objects from the LFS server as normal.

Edge case: git may lazily fetch an LFS pointer blob during tree walking and trigger the smudge
filter prematurely before `git lfs pull` runs. Mitigation: set `GIT_LFS_SKIP_SMUDGE=1` during
clone, then run `git lfs pull` explicitly after checkout.

#### Sparse checkout (`git sparse-checkout`)

The smudge filter only runs on files that are checked out. Files outside the sparse set do not
trigger LFS downloads. `git lfs pull` also respects the sparse checkout — it only fetches objects
referenced by checked-out paths.

This is a useful performance optimization: a sparse checkout of a large monorepo with heavy LFS
usage only downloads LFS objects for the checked-out subtree.

---

### 5. `git-lfs` binary detection reliability across platforms

Recommended approach: `exec.LookPath("git-lfs")` with a fallback probe via `git lfs version`
(check exit code 0). The `git lfs version` probe is slightly more reliable because it verifies
that *git* can resolve the LFS extension — not just that a binary exists somewhere on PATH.

| Platform | Notes |
|---|---|
| **Linux** | Installed via package manager. Binary reliably in PATH. Some minimal Docker images lack it. |
| **macOS (Intel)** | Homebrew installs to `/usr/local/bin`. Works if PATH includes it. |
| **macOS (Apple Silicon)** | Homebrew installs to `/opt/homebrew/bin`. Agents started as launchd daemons may not have this in PATH — must ensure the agent's launch environment includes the Homebrew bin path. |
| **Windows** | Git for Windows bundles git-lfs at `C:\Program Files\Git\mingw64\bin\git-lfs.exe`. `exec.LookPath` works if the Git installer configured PATH. Standalone LFS installer puts it at a different location. |

---

### 6. Error behavior when git-lfs is installed but not configured (no `.lfsconfig`)

**No `.lfsconfig` is the normal case; its absence does not cause errors.**

Without `.lfsconfig`, git-lfs defaults to:
- LFS endpoint: `{origin_remote_url}/info/lfs`
- Transfer adapter: basic HTTP
- Credentials: inherited from git credential helpers

For repos hosted on GitHub, GitLab, Bitbucket, or Buildkite-managed SCMs, native LFS support is
served at `{repo_url}/info/lfs` — no `.lfsconfig` required.

`.lfsconfig` is only needed when:
- LFS objects are stored on a separate server (e.g., Artifactory, custom LFS server).
- The LFS endpoint requires different auth credentials from git.
- A non-default transfer adapter is needed (e.g., SSH transfer).

`git lfs install --local` runs cleanly and `git lfs pull` works without any `.lfsconfig`. Absence
of `.lfsconfig` is not an error condition.

---

### 7. Performance implications of `git lfs pull` on repos with many LFS-tracked files

LFS is network/IO-bound; the batch API and concurrency mitigate most per-file overhead.

- **Batch API**: git-lfs sends a single HTTP POST with all required object OIDs to
  `{remote}/info/lfs/objects/batch`. The server returns pre-signed download URLs in one response.
  Network round-trips are O(1) regardless of file count.
- **Concurrent downloads**: Default `lfs.concurrenttransfers` is 8 (git-lfs 2.x+; was 3 in older
  versions). Parallelism significantly reduces wall-clock time for large numbers of files.
- **Content-addressable dedup**: Identical content shared across branches/paths is stored and
  downloaded once.
- **CI-specific concern**: On the first build, all objects must be downloaded. Subsequent builds
  reuse the local LFS cache at `.git/lfs/objects/`. If the checkout directory is wiped between
  builds (fresh clone), the cache is also wiped — no reuse benefit.

**Optimization levers:**
- Preserve `.git/lfs/objects/` across builds when not doing full fresh clones.
- Set `GIT_LFS_SKIP_SMUDGE=1` during clone and run `git lfs pull` explicitly after — avoids
  the smudge filter running serially per-file during checkout and uses parallel batch download
  instead.
- Tune `lfs.concurrenttransfers` upward for high-bandwidth agents.

---

### 8. `git lfs install --local` is idempotent

**Safe to run multiple times.**

Running `git lfs install --local` repeatedly:
- Re-writes the same `filter.lfs.*` keys to `.git/config` with identical values — idempotent
  git config writes.
- Overwrites hook scripts in `.git/hooks/` (`pre-push`, `post-checkout`, `post-commit`,
  `post-merge`) with the same stock content.
- Exits 0 on every run.

**Edge case**: repositories with *custom* hooks that wrap or chain git-lfs will have those hooks
overwritten with the stock git-lfs hooks. For agent-managed checkout directories this is not a
concern.

`git lfs install --local` can be called unconditionally before `git lfs pull` without guard logic.

---

### 9. LFS content in git submodules

When a repository contains submodules that themselves track LFS files, `git lfs fetch` run at
the top level only fetches objects for the top-level repository. Each submodule has its own
`.git` directory and its own LFS object store at `<submodule-path>/.git/lfs/objects/`.

Because `GIT_LFS_SKIP_SMUDGE=1` is set in the process environment before `git checkout` runs,
the variable is **inherited by `git submodule update`**, which also suppresses the smudge filter
within each submodule. Submodule LFS pointer files therefore remain as raw pointer text on disk
after `git submodule update` completes — even if the smudge filter is correctly configured in the
submodule.

The agent must run `git lfs fetch` + `git lfs checkout` inside each submodule directory after the
top-level LFS fetch, when both LFS and submodules are enabled:

```
git -C <submodule-path> lfs install --local
git -C <submodule-path> lfs fetch [--include=<pattern>] [--exclude=<pattern>]
git -C <submodule-path> lfs checkout
```

`BUILDKITE_GIT_LFS_FETCH_INCLUDE` and `BUILDKITE_GIT_LFS_FETCH_EXCLUDE`, if set, are forwarded
to each submodule fetch unchanged. This may not always align with the submodule's directory
structure, but it matches the user's stated intent and avoids introducing a separate set of
submodule-specific filter variables.

---

## Design Rationale

### `git lfs fetch + checkout` over `git lfs pull`

The agent uses `git lfs fetch` + `git lfs checkout` as two explicit steps rather than `git lfs pull`
(which is just an alias for the two combined). This mirrors the agent's existing `git fetch` +
`git checkout` pattern, but **the reason is different**.

For plain git, `git pull` is avoided because it performs a merge/rebase — wrong for CI, where you
want a clean checkout of a specific commit, not a merge. This is especially important with git
mirror repos (`--reference`/`--dissociate`), where the commit objects are already present locally
and merging into a bare reference clone makes no sense.

For git LFS, `git lfs pull` has no merge semantics — it is purely `git lfs fetch` + `git lfs
checkout` bundled together. The mirrors argument does not carry over.

The actual motivation for the split is the **`GIT_LFS_SKIP_SMUDGE=1` pattern**:

1. `GIT_LFS_SKIP_SMUDGE=1` is set in the shell environment before `git checkout` runs.
   This prevents the smudge filter from firing inline (serially, one file at a time) as git
   checks out the working tree. LFS pointer files land on disk as-is rather than triggering
   individual downloads.
2. After `git checkout` completes, `git lfs fetch` downloads all required LFS objects in a
   single parallel batch request to the LFS server (O(1) round-trips via the batch API,
   concurrent transfers).
3. `git lfs checkout` then replaces the pointer files with real content using only the local
   LFS cache — no further network calls.

Using `git lfs pull` directly would bypass step 1: the smudge filter would fire during
`git checkout`, making downloads serial and unparallelised. The explicit split is the only way to
get batch parallel downloads while keeping the agent in control of when LFS content materialises.

### Always use `git lfs install --local`

The agent always runs `git lfs install --local` and does not expose an `install_scope` option.

`git lfs install` (no flag) writes the LFS filter config and hooks to `~/.gitconfig` and the
global hooks directory, making LFS active for every repository on the host for the lifetime of
that user. `git lfs install --local` writes the same config to `.git/config` and `.git/hooks/`,
scoping it entirely to the current repository.

There is no meaningful benefit to `global` scope in an agent context:

- **Ephemeral agents** (containers, Kubernetes pods): the global config disappears with the
  environment, so `global` buys nothing over `--local`.
- **Persistent agents on shared hosts**: `global` scope pollutes `~/.gitconfig` for every
  subsequent git operation on that host — including repos that do not use LFS, and builds from
  other pipelines that may run concurrently on the same agent user.
- **The agent already controls the checkout flow**: since `git lfs install` is called as part of
  the managed checkout, `--local` always has the `.git/` directory it requires and achieves the
  same result as `global` for the repo being built.

Configuring LFS globally is an infrastructure concern (host or image setup), not a per-step
concern. A pipeline author has no valid reason to write to the host's global git config from a
`checkout:` block.

### Typed `include`/`exclude` fields over a raw fetch flags string

`git lfs fetch` accepts many flags, but most are not appropriate for CI:

| Flag | CI useful? | Reason |
|---|---|---|
| _(no flags)_ | Yes | Fetches objects for current HEAD — the primary use case |
| `--include`/`-I` | Yes | Limits fetch to matching path patterns — directly useful for sparse checkout |
| `--exclude`/`-X` | Yes | Excludes paths from fetch — complement to `--include` |
| `--recent`/`-r` | No | Pre-warms cache for nearby branches; CI agents check out one commit and never switch branches mid-build |
| `--all`/`-a` | No | Fetches every LFS object from every ref — wasteful and expensive in CI |
| `--prune`/`-p` | No | Deletes locally cached objects; side-effectful cleanup already handled by the separate `prune` option |
| `--dry-run`/`-d` | No | Never useful in CI |

The only flags with a legitimate CI use case are `--include` and `--exclude`, both of which are
relevant to **sparse checkout**. With `GIT_LFS_SKIP_SMUDGE=1`, `git lfs fetch` without path
filtering downloads ALL LFS objects referenced in HEAD, including files outside the sparse set
that `git lfs checkout` will never materialise. `--include`/`--exclude` constrains the fetch to
match the sparse pattern, avoiding unnecessary bandwidth.

**Shallow clones** require no special flags — LFS objects are fetched from the batch API
independently of git history depth, so the default no-flag behaviour is correct for any clone
depth.

Rather than a raw string (which lets users pass `--recent`, `--all`, etc.), the agent exposes
`include` and `exclude` as explicit typed fields. This prevents misuse while directly addressing
the only valid CI use case.

--- 

## Implementation Proposal

### Pipeline YAML

```yaml
steps:
  - command: "build.sh"
    checkout:
      lfs:
        prune: false                   # optional. default: false
        fetch:
          include: "assets/models/**"  # optional. passed as --include to git lfs fetch
          exclude: "assets/legacy/**"  # optional. passed as --exclude to git lfs fetch
```

An empty `lfs:` block (or `lfs: {}`) is valid and means LFS enabled with all defaults —
equivalent to `BUILDKITE_GIT_LFS_ENABLED=true` with no fetch filters and no prune.
An absent or empty `fetch:` block means no path filtering: `git lfs fetch` runs without
`--include` or `--exclude` and downloads all LFS objects for current HEAD.

### Proposed environment variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `BUILDKITE_GIT_LFS_ENABLED` | bool | `false` | Set to `true` when an `lfs:` block is present in the step. Absent if `lfs:` is omitted. |
| `BUILDKITE_GIT_LFS_FETCH_INCLUDE` | string | `""` | Path pattern forwarded as `--include` to `git lfs fetch`. Empty = no filter. |
| `BUILDKITE_GIT_LFS_FETCH_EXCLUDE` | string | `""` | Path pattern forwarded as `--exclude` to `git lfs fetch`. Empty = no filter. |
| `BUILDKITE_GIT_LFS_PRUNE` | bool | `false` | When `true`, runs `git lfs prune` in the pre-exit phase. |

### Fallback defaults when YAML fields are omitted:**

| Scenario | Env var result |
|---|---|
| `lfs:` block absent | `BUILDKITE_GIT_LFS_ENABLED` absent (treated as `false`) |
| `lfs:` block present (even if empty, e.g. `lfs: {}`) | `BUILDKITE_GIT_LFS_ENABLED=true` |
| `fetch:` block absent OR `fetch: {}` | `BUILDKITE_GIT_LFS_FETCH_INCLUDE=""`, `BUILDKITE_GIT_LFS_FETCH_EXCLUDE=""` (no path filter) |
| `fetch.include:` absent | `BUILDKITE_GIT_LFS_FETCH_INCLUDE=""` |
| `fetch.exclude:` absent | `BUILDKITE_GIT_LFS_FETCH_EXCLUDE=""` |
| `prune:` absent | `BUILDKITE_GIT_LFS_PRUNE=false` |

`BUILDKITE_GIT_LFS_ENABLED=true` set directly as an env var (without a YAML `lfs:` block) is
also a supported path. `BUILDKITE_GIT_LFS_FETCH_INCLUDE`, `BUILDKITE_GIT_LFS_FETCH_EXCLUDE`, and
`BUILDKITE_GIT_LFS_PRUNE` are respected independently and follow the same defaults above.

> **Non-boolean values for `BUILDKITE_GIT_LFS_ENABLED` and `BUILDKITE_GIT_LFS_PRUNE`**: the
> agent's env tag reflection uses `strconv.ParseBool`, which accepts `"1"`, `"t"`, `"T"`,
> `"TRUE"`, `"true"`, `"True"`, `"0"`, `"f"`, `"F"`, `"FALSE"`, `"false"`, `"False"`. Any other
> value (e.g. `"yes"`, `"on"`) causes a parse error. The agent should emit a `Warningf`-level
> message and disable LFS rather than failing the build or proceeding with an undefined value:
> `"BUILDKITE_GIT_LFS_ENABLED has invalid value %q: %v; disabling LFS operations"`

### Operation logic

```
if BUILDKITE_GIT_LFS_ENABLED is absent or false
  → no LFS operations performed

if BUILDKITE_GIT_LFS_ENABLED = true

  if git-lfs binary not found  # probe: exec.LookPath("git-lfs") + git lfs version fallback
    → WARN: "git-lfs not found, skipping LFS operations: <error>"
    → exit  # skip all LFS steps; build continues

  # Step 1: Install (before gitCheckout, after git clone)
  → git lfs install --local     # always local; writes filter config to .git/config

  # During gitCheckout: smudge is disabled so checkout writes pointer
  # files to disk rather than downloading objects inline.
  # GIT_LFS_SKIP_SMUDGE=1 is force-set, overriding any existing value in the
  # environment. This is intentional: the fetch+checkout pattern requires it
  # regardless of what the user or repo has configured.
  → set GIT_LFS_SKIP_SMUDGE=1 in shell env before gitCheckout

  # Step 2a: Fetch + checkout top-level repo (after gitCheckout and submodule operations)
  build fetch args:
    args = ["lfs", "fetch"]
    if BUILDKITE_GIT_LFS_FETCH_INCLUDE is non-empty → append "--include=<value>"
    if BUILDKITE_GIT_LFS_FETCH_EXCLUDE is non-empty → append "--exclude=<value>"
    # invalid glob pattern in include/exclude → git lfs fetch exits non-zero → fail build
    # both empty (default): fetches all LFS objects for current HEAD
  → git <args>                  # fetches objects for current HEAD (path-filtered if set)
  → git lfs checkout            # replaces pointer files with real content
                                # no network call — uses local cache only

  # Step 2b: Fetch + checkout each submodule (only when submodules are enabled)
  # GIT_LFS_SKIP_SMUDGE=1 is inherited by git submodule update, leaving LFS pointer
  # files in each submodule. Each submodule must be handled independently.
  if BUILDKITE_GIT_SUBMODULES = true
    for each submodule path (via git submodule foreach --quiet --recursive pwd):
      → git -C <path> lfs install --local
      → git -C <path> lfs fetch [--include=<value>] [--exclude=<value>]
      → git -C <path> lfs checkout

  # Step 3: Prune (pre-exit phase, while checkout dir still exists)
  if BUILDKITE_GIT_LFS_PRUNE = false  (default)
    → no git lfs prune          # recommended for ephemeral agents
  if BUILDKITE_GIT_LFS_PRUNE = true
    → git lfs prune             # cleans local LFS object cache
                                # only useful for persistent agents
```

> **agent-stack-k8s note**: the pre-exit phase runs in a different container from the checkout
> phase, so there will be no LFS objects to prune. `lfs.prune` should be documented as a
> persistent-agent-only option.

### Command sequence and failure handling

The table below shows the exact shell commands in execution order, positioned relative to the
existing checkout operations, together with the expected failure behaviour for each.

```
# ── Existing: clone or fetch ──────────────────────────────────────────────────────
git clone <flags> <repo> .
  OR
git fetch <flags> origin <refspec>

# ── LFS step 1: probe + install (after repo initialised, before git checkout) ─────
git lfs version                          # probe — exit 0 = binary present
git lfs install --local                  # writes filter config to .git/config

# ── Existing + LFS: checkout ──────────────────────────────────────────────────────
# GIT_LFS_SKIP_SMUDGE=1 is force-set in the process environment, overriding any
# existing value (including a user-set GIT_LFS_SKIP_SMUDGE=0). This is required
# for the fetch+checkout pattern regardless of what the environment already contains.
git checkout --force <commit>            # pointer files land on disk, no downloads

# ── Existing: submodules (if enabled) ─────────────────────────────────────────────
# GIT_LFS_SKIP_SMUDGE=1 is inherited here, suppressing smudge in submodules too.
git submodule sync --recursive
git submodule update --init --recursive <flags>

# ── LFS step 2a: fetch + materialise top-level repo (before git clean) ────────────
# Flags are only appended when the corresponding env var is non-empty.
# Default (both empty): fetches all LFS objects for current HEAD — no path filter.
# Invalid glob in --include/--exclude causes git lfs fetch to exit non-zero → build fails.
git lfs fetch [--include=<pattern>] [--exclude=<pattern>]
git lfs checkout                         # replaces pointer files — no network call

# ── LFS step 2b: fetch + materialise each submodule (if submodules enabled) ───────
# Required because GIT_LFS_SKIP_SMUDGE=1 was inherited by git submodule update.
git submodule foreach --quiet --recursive pwd  # enumerate submodule paths
# For each <submodule-path>:
git -C <submodule-path> lfs install --local
git -C <submodule-path> lfs fetch [--include=<pattern>] [--exclude=<pattern>]
git -C <submodule-path> lfs checkout

# ── Existing: clean ───────────────────────────────────────────────────────────────
git clean <flags>

# ── LFS step 3: prune (tearDown / pre-exit phase, only if BUILDKITE_GIT_LFS_PRUNE=true)
git lfs prune
```

**Failure behaviour per command:**

| Command | On failure | Error message | Reason |
|---|---|---|---|
| `git lfs version` / `exec.LookPath` | Warn, skip all LFS, continue build | `"git-lfs not found, skipping LFS operations: <err>"` | Missing binary is a host config issue; degrading gracefully avoids breaking builds on agents without git-lfs |
| Non-boolean `BUILDKITE_GIT_LFS_ENABLED` | Warn, disable LFS, continue build | `"BUILDKITE_GIT_LFS_ENABLED has invalid value %q: %v; disabling LFS operations"` | Misconfiguration should not fail the build; disabling LFS is the safe fallback |
| `git lfs install --local` (top-level) | Fail the build | `"git lfs install: <err>"` | Without filter config in `.git/config`, subsequent LFS operations are undefined |
| `git lfs fetch` (invalid glob) | Fail the build | `"git lfs fetch: <err>"` | git-lfs exits non-zero on an unparseable pattern |
| `git lfs fetch` (all other failures) | Fail the build | `"git lfs fetch: <err>"` | LFS objects missing from cache means `git lfs checkout` leaves raw pointer text on disk |
| `git lfs checkout` | Fail the build | `"git lfs checkout: <err>"` | Pointer files remain instead of real content — distinct from fetch failure in logs |
| `git submodule foreach` (listing paths) | Fail the build | `"listing submodules for LFS: <err>"` | Cannot proceed with submodule LFS materialisation without the path list |
| `git lfs install --local` (per submodule) | Fail the build | `"git lfs install in submodule %q: <err>"` | Same consequence as top-level install failure, scoped to the submodule |
| `git lfs fetch/checkout` (per submodule) | Fail the build | `"submodule %q: git lfs fetch: <err>"` or `"submodule %q: git lfs checkout: <err>"` | Submodule LFS content not materialised has the same consequence as top-level failure |
| `git lfs prune` | Warn only, continue build | `"git lfs prune failed: <err>"` | Prune is cleanup; failure leaves stale cached objects but does not affect build correctness |


---

## Agent Codebase Integration Points

The agent has no existing LFS functionality. This section maps where LFS support would slot into
the codebase, validated against the current source.


### Files to change

#### `internal/job/config.go` — ExecutorConfig (line 25)

Add four fields after `GitSubmodules` (line 54), following the same struct tag pattern:

```go
// Whether to enable Git LFS operations during checkout
GitLFSEnabled bool `env:"BUILDKITE_GIT_LFS_ENABLED"`

// Path pattern passed as --include to "git lfs fetch". Empty = no filter.
GitLFSFetchInclude string `env:"BUILDKITE_GIT_LFS_FETCH_INCLUDE"`

// Path pattern passed as --exclude to "git lfs fetch". Empty = no filter.
GitLFSFetchExclude string `env:"BUILDKITE_GIT_LFS_FETCH_EXCLUDE"`

// Whether to run git lfs prune in the pre-exit phase
GitLFSPrune bool `env:"BUILDKITE_GIT_LFS_PRUNE"`
```

`ReadFromEnvironment` (line 214) uses reflection over struct tags — no changes needed there once
the fields are added. Bool fields are parsed via `strconv.ParseBool`, which accepts `"1"`,
`"t"`, `"T"`, `"TRUE"`, `"true"`, `"True"`, `"0"`, `"f"`, `"F"`, `"FALSE"`, `"false"`,
`"False"`. Any other value (e.g. `"yes"`, `"on"`) returns a parse error; emit a `Warningf` and
treat the field as `false`:
```go
e.shell.Warningf("BUILDKITE_GIT_LFS_ENABLED has invalid value %q: %v; disabling LFS operations", val, err)
```

#### `clicommand/bootstrap.go` — BootstrapConfig (line 50)

Mirror each new field with a `cli:` tag, following `GitSubmodules` (line 62) as the model. Add
the corresponding `cli.Flag` entries in the git flags group (lines 237–249).

#### `clicommand/global.go` and `clicommand/agent_start.go`

Add CLI flag variable constants in `global.go`. Add agent-level defaults in `AgentStartConfig`
in `agent_start.go` (LFS disabled by default).

#### `agent/job_runner.go` — createEnvironment (line 395)

Propagate the new env vars to the bootstrap process. The existing `GitSubmodules` pattern
(lines 568–570) is the model to follow:

```go
// Disable LFS at agent level if not configured; allow step env to override.
if !r.conf.AgentConfiguration.GitLFSEnabled {
    setEnv("BUILDKITE_GIT_LFS_ENABLED", "false")
}
// Always propagate fetch filter and prune vars — empty string is a valid default
// (no filter / no prune) and step-level env vars can override them.
setEnv("BUILDKITE_GIT_LFS_FETCH_INCLUDE", r.conf.AgentConfiguration.GitLFSFetchInclude)
setEnv("BUILDKITE_GIT_LFS_FETCH_EXCLUDE", r.conf.AgentConfiguration.GitLFSFetchExclude)
setEnv("BUILDKITE_GIT_LFS_PRUNE", strconv.FormatBool(r.conf.AgentConfiguration.GitLFSPrune))
```

#### `internal/job/git.go` — new helpers

Add `detectGitLFS`, `gitLFSInstall`, and `gitLFSFetchCheckout` following the pattern of existing
helpers (`gitClone` at line 92, `gitClean` at line 104):

```go
// detectGitLFS probes for the git-lfs binary. It tries exec.LookPath first for
// speed, then falls back to "git lfs version" which also verifies that git itself
// can resolve the LFS extension (e.g. on Apple Silicon with a launchd PATH).
func detectGitLFS(ctx context.Context, sh *shell.Shell) error {
    if _, err := exec.LookPath("git-lfs"); err == nil {
        return nil
    }
    return sh.Command("git", "lfs", "version").Run(ctx)
}

func gitLFSInstall(ctx context.Context, sh *shell.Shell) error {
    return sh.Command("git", "lfs", "install", "--local").Run(ctx)
}

// gitLFSFetchCheckout fetches LFS objects for the current HEAD then materialises
// them. Fetch and checkout failures are wrapped with distinct messages so that a
// caller can tell which step failed from the error string alone.
func gitLFSFetchCheckout(ctx context.Context, sh *shell.Shell, include, exclude string) error {
    fetchArgs := []string{"lfs", "fetch"}
    if include != "" {
        fetchArgs = append(fetchArgs, "--include="+include)
    }
    if exclude != "" {
        fetchArgs = append(fetchArgs, "--exclude="+exclude)
    }
    if err := sh.Command("git", fetchArgs...).Run(ctx); err != nil {
        return fmt.Errorf("git lfs fetch: %w", err)
    }
    if err := sh.Command("git", "lfs", "checkout").Run(ctx); err != nil {
        return fmt.Errorf("git lfs checkout: %w", err)
    }
    return nil
}
```

#### `internal/job/checkout.go` — defaultCheckoutPhase (line 811)

> **Note**: the guide references line 713, but `defaultCheckoutPhase` actually starts at
> line 811 in the current source. Submodule handling runs lines 933–1019, and the final
> `gitClean` is at lines 1027–1035. Line numbers below reflect the actual file.

Two insertion points inside `defaultCheckoutPhase`:

**Before `gitCheckout` (~line 921)** — install LFS and disable smudge:

```go
if e.GitLFSEnabled {
    if err := detectGitLFS(ctx, e.shell); err != nil {
        // Degrade gracefully: binary missing is a host config issue, not a code
        // issue. All subsequent LFS steps are skipped; the build continues.
        e.shell.Warningf("git-lfs not found, skipping LFS operations: %v", err)
    } else {
        if err := gitLFSInstall(ctx, e.shell); err != nil {
            return fmt.Errorf("git lfs install: %w", err)
        }
        // Force-set GIT_LFS_SKIP_SMUDGE=1, overriding any existing value in the
        // environment. Required for the fetch+checkout pattern; the value is
        // intentionally not restored after checkout — git lfs checkout materialises
        // files from the local cache without triggering the smudge filter anyway.
        e.shell.Env.Set("GIT_LFS_SKIP_SMUDGE", "1")
    }
}
// existing gitCheckout call follows
```

**After the submodule block (~line 1020), before final gitClean (~line 1027)** — fetch and
replace pointer files for the top-level repo and each submodule:

```go
if e.GitLFSEnabled {
    // GitLFSFetchInclude and GitLFSFetchExclude default to ""; empty string
    // means no flag is appended — git lfs fetch runs without path filtering.
    // gitLFSFetchCheckout returns distinct "git lfs fetch: ..." or
    // "git lfs checkout: ..." errors so the failing step is clear from logs.
    if err := gitLFSFetchCheckout(ctx, e.shell, e.GitLFSFetchInclude, e.GitLFSFetchExclude); err != nil {
        return err
    }

    // GIT_LFS_SKIP_SMUDGE=1 is inherited by git submodule update, leaving LFS
    // pointer files in each submodule. Install + materialise per submodule.
    if e.GitSubmodules {
        out, err := e.shell.Command("git", "submodule", "foreach", "--quiet", "--recursive", "pwd").
            RunAndCaptureStdout(ctx)
        if err != nil {
            return fmt.Errorf("listing submodules for LFS: %w", err)
        }
        for _, subPath := range strings.Fields(out) {
            if err := gitLFSInstall(ctx, e.shell.WithDir(subPath)); err != nil {
                return fmt.Errorf("git lfs install in submodule %q: %w", subPath, err)
            }
            if err := gitLFSFetchCheckout(ctx, e.shell.WithDir(subPath), e.GitLFSFetchInclude, e.GitLFSFetchExclude); err != nil {
                return fmt.Errorf("submodule %q: %w", subPath, err)
            }
        }
    }
}
```

Binary detection follows the `findPathToSSHTools` pattern in `internal/job/ssh.go` (line 68) —
use `sh.AbsolutePath("git-lfs")` or run `git lfs version` and check the exit code.

#### `internal/job/executor.go` — tearDown (line 1001)

`tearDown` is where pre-exit hooks are executed (lines 1013–1023). LFS prune runs after all
global/local/plugin pre-exit hooks, while the checkout directory still exists. Gate it on both
`GitLFSEnabled` and `GitLFSPrune`, and only when the checkout phase was included (to match the
existing `e.includePhase("command")` guard pattern):

```go
if e.GitLFSEnabled && e.GitLFSPrune && e.includePhase("checkout") {
    if err = e.shell.Command("git", "lfs", "prune").Run(ctx); err != nil {
        e.shell.Warningf("git lfs prune failed: %v", err)
    }
}
```

#### `internal/job/checkout_test.go`

Add unit and integration tests covering:
- LFS disabled (no LFS calls made)
- LFS enabled, binary absent (warning emitted, no failure)
- LFS fetch with no filters, with `include`, with `exclude`, and with both
- LFS prune in teardown when `prune: true`
- Interaction with submodule-enabled repos


---

## Go-pipeline Codebase Changes

#### `step_command_checkout.go`

Define three new structs to model the `checkout.lfs` YAML block. All three structs carry
`RemainingFields` so that unknown keys survive an unmarshal/marshal round-trip.

```go
// Checkout models the checkout settings for a command step.
type Checkout struct {
    LFS             *LFS           `yaml:"lfs,omitempty"`
    RemainingFields map[string]any `yaml:",inline"`
}

// LFS models the lfs block inside a checkout block.
type LFS struct {
    Prune           bool           `yaml:"prune,omitempty"`
    Fetch           *LFSFetch      `yaml:"fetch,omitempty"`
    RemainingFields map[string]any `yaml:",inline"`
}

// LFSFetch models the fetch block inside an lfs block.
type LFSFetch struct {
    Include         string         `yaml:"include,omitempty"`
    Exclude         string         `yaml:"exclude,omitempty"`
    RemainingFields map[string]any `yaml:",inline"`
}
```

**Pointer semantics** (`*LFS`, `*LFSFetch`) correctly model the proposal's presence/absence
distinction:
- `lfs:` absent → `Checkout.LFS == nil` (LFS disabled)
- `lfs: {}` present but empty → `Checkout.LFS != nil`, all fields zero (LFS enabled with defaults)
- `fetch:` absent → `LFS.Fetch == nil` (no path filtering)

Since `Checkout`, `LFS`, and `LFSFetch` are always maps (never a scalar or array), none need a
custom `UnmarshalOrdered`. The `ordered` package's default struct unmarshaling handles nested
structs and `yaml:",inline"` maps automatically.

Because `encoding/json` has no concept of `inline`, each struct needs a `MarshalJSON` method
calling `inlineFriendlyMarshalJSON` — the same pattern used by `Cache`. Compile-time interface
assertions should guard this:

```go
var _ interface {
    json.Marshaler
} = (*Checkout)(nil)
```

`install_scope` is **not** a field in any of these structs. The design doc is explicit that the
agent always runs `git lfs install --local` and does not expose an `install_scope` option.

---

#### `step_command_checkout_test.go`

Tests should cover both marshal (struct → JSON) and unmarshal (ordered map → struct) directions,
following the same pattern as `step_command_cache_test.go`.

#### Proposed test cases — assessment

| Proposed case | Assessment |
|---|---|
| empty (`lfs: {}`) | ✓ correct — tests non-nil `*LFS` with all zero values |
| lfs with fetch only | ✓ correct — tests `Fetch != nil`, `Prune == false` |
| lfs with all fields | ✓ correct — tests prune + fetch.include + fetch.exclude together |
| **install_scope only** | **✗ wrong** — `install_scope` is not a field in the proposal; remove this case |
| extra fields passthrough | ✓ correct — tests `RemainingFields` on `LFS` and `LFSFetch` |

Replace `install_scope only` with **`prune: true` only** (no `fetch:` block), which covers the
meaningful gap: `Prune` set, `Fetch == nil`.

#### Complete recommended test matrix

| Case | What it exercises |
|---|---|
| `lfs:` absent | `Checkout.LFS == nil` |
| `lfs: {}` | `LFS != nil`, all zero values — LFS enabled with defaults |
| `lfs: {prune: true}` | `Prune` set, `Fetch == nil` |
| `lfs: {fetch: {include: "..."}}` | `Fetch` present, include only |
| `lfs: {fetch: {exclude: "..."}}` | `Fetch` present, exclude only |
| all fields | `prune: true` + `fetch.include` + `fetch.exclude` |
| extra fields in `lfs:` | `LFS.RemainingFields` populated |
| extra fields in `fetch:` | `LFSFetch.RemainingFields` populated |

---

## Pipeline-schema Codebase Changes

### `schema.json`

Two changes were made:

**1. New `checkout` definition** added to the `definitions` section (alphabetically after `cancelOnBuildFailing`):

```json
"checkout": {
  "type": "object",
  "description": "Git checkout configuration for the step",
  "properties": {
    "lfs": {
      "description": "Git LFS configuration. An empty block (or null) enables LFS with all defaults.",
      "anyOf": [
        { "type": "null" },
        {
          "type": "object",
          "properties": {
            "prune": {
              "type": "boolean",
              "description": "Run git lfs prune in the pre-exit phase",
              "default": false
            },
            "fetch": {
              "type": "object",
              "description": "Path filtering for git lfs fetch",
              "properties": {
                "include": {
                  "type": "string",
                  "description": "Path pattern passed as --include to git lfs fetch",
                  "examples": ["assets/models/**"]
                },
                "exclude": {
                  "type": "string",
                  "description": "Path pattern passed as --exclude to git lfs fetch",
                  "examples": ["assets/legacy/**"]
                }
              },
              "additionalProperties": false
            }
          },
          "additionalProperties": false
        }
      ]
    }
  },
  "additionalProperties": false
}
```

**2. `checkout` property added to `commandStep`** (between `cancel_on_build_failing` and `command`):

```json
"checkout": {
  "$ref": "#/definitions/checkout"
}
```

### `test/valid-pipelines/checkout.yml`

New fixture file covering:
- `lfs: {}` — empty object (LFS enabled, all defaults)
- `lfs: ~` — null value (equivalent to empty block)
- `lfs: {prune: true}` — prune only
- `lfs: {prune: false, fetch: {include: "...", exclude: "..."}}` — all fields
- `lfs: {fetch: {include: "..."}}` — include filter only
- `lfs: {fetch: {exclude: "..."}}` — exclude filter only

### `test/schema.test.js`

New test case added:

```js
it("should validate checkout with lfs", function() {
  validate("checkout.yml");
});
```
