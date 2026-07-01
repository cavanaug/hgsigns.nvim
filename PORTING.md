# Porting Guide: gitsigns.nvim → hgsigns.nvim

This document is for maintainers who want to cherry-pick upstream
[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) commits into this
Mercurial fork.  Everything here was established during the initial port.

**Branch model.** Two branches share this repository:

- `main` / `master` — a *mirror* of upstream gitsigns.nvim, used only to track
  and review new upstream work. No Mercurial code lives here.
- `mercurial` — **hgsigns.nvim**, a Mercurial **sibling** to gitsigns.nvim.
  This branch is a *wholesale* port to Mercurial and must contain **no Git
  references**, with one deliberate exception: highlight/color groups are
  shared with gitsigns so the two siblings render identically (see section 1).

Porting means translating an upstream gitsigns (Git) change into its Mercurial
equivalent on the `mercurial` branch — not carrying the Git implementation
across. Upstream `git` commands are the *source* you translate **from**; the
shipped result speaks only `hg`.

---

## 1. Fork Anchor and Architecture

The fork was performed as a **rename-first** operation:

- The very first commit in this repository renames every `gitsigns`/`Gitsigns`/
  `GitSigns` identifier to its `hgsigns`/`Hgsigns` equivalent, with no VCS
  logic changed.
- All subsequent commits replace the Git backend logic with Mercurial logic on
  top of that clean rename baseline.

**This branch is Mercurial-only.** It is a sibling to gitsigns.nvim, intended
to run *alongside* gitsigns (one handles Git buffers, the other handles
Mercurial buffers). The shipped plugin must not invoke `git` at runtime. The
only intentional overlap with gitsigns is **highlight/color groups** — hgsigns
mirrors gitsigns' visual behavior so signs, blame, and diffs look the same in
both. (Note: the highlight groups themselves are renamed to `Hgsigns*` per
section 2; "shared" here means the rendering behavior is kept deliberately
identical, not that the group names are reused.)

### Historical names

Some names are inherited from the rename anchor and do **not** imply a Git
dependency:

- The backend directory is still `lua/hgsigns/git/` and the runtime type prefix
  is still `Hgsigns.Git.*`. These are legacy labels; the code behind them
  speaks only Mercurial.
- `lua/hgsigns/git/cmd.lua` runs `hg` exclusively — there is no `vcs` switch and
  no git argv/env branch. `lua/hgsigns/git/repo.lua` resolves repos via `hg root`
  only (there is no `get_info_git`). The Git backend that the upstream fork
  started from has been fully removed on this branch.

> When porting, keep it this way: never (re)introduce a `git` CLI call or a
> `vcs = 'git'` code path. Translate the upstream git command to `hg`
> (section 3) so the shipped plugin stays Git-free.

When cherry-picking upstream fixes, diff the upstream commit against this
rename anchor to separate structural identifier changes from logic changes.
Conflicts that touch only identifiers are mechanical (apply the rename map);
conflicts that touch VCS command arguments require translating the Git command
to its Mercurial equivalent (see sections 3–5 below).

---

## 2. Module and Runtime Rename Map

| gitsigns (upstream) | hgsigns (this fork) |
|---|---|
| `lua/gitsigns/` | `lua/hgsigns/` |
| `require('gitsigns')` | `require('hgsigns')` |
| `require('gitsigns.foo')` | `require('hgsigns.foo')` |
| `:Gitsigns <action>` | `:Hgsigns <action>` |
| Highlight group `Gitsigns*` | `Hgsigns*` |
| Highlight group `GitSigns*` | `Hgsigns*` |
| Buffer variable `b:gitsigns_*` | `b:hgsigns_*` |
| Autocommand event `User GitsignsUpdate` | `User HgsignsUpdate` |
| Lua type prefix `Gitsigns.` | `Hgsigns.` |
| Config key `gitsigns` (e.g. in statusline helpers) | `hgsigns` |

> **Rule of thumb:** every runtime identifier — commands, events,
> augroups, filetypes, URI schemes, highlight group prefixes — uses the single
> lowercase project name `hgsigns` / title-case `Hgsigns`.  The upstream dual
> spellings (`Gitsigns` *and* `GitSigns`) are collapsed into one. This includes
> the highlight groups: hgsigns defines its own `Hgsigns*` groups (see
> `lua/hgsigns/highlight.lua`) and keeps their visual behavior matched to the
> gitsigns originals.

---

## 3. VCS Command Translation Table

When an upstream commit introduces or changes a `git` command, translate it to
the Mercurial equivalent below. The Git command is the **source** you port
*from*; the shipped `mercurial` branch runs only the `hg` form. Do not leave a
`git` invocation behind "just in case" — that would reintroduce a Git
dependency this branch is meant to be free of (see section 1).

All `hg` commands run through `lua/hgsigns/git/cmd.lua` with the stabilization
environment described in section 5.

| Git command (upstream source) | Mercurial equivalent (shipped) | Notes |
|---|---|---|
| `git rev-parse --show-toplevel` | `hg root` | Returns repo root path |
| `git rev-parse HEAD` | `hg parents --template {node}` | Full 40-char node hash |
| `git diff [--name-status] [base]` | `hg diff [--name-status] [base]` | Git-format diff via `--git` flag where needed |
| `git log --follow …` | `hg log --follow …` | Follow renames across revisions |
| `git show <rev>:<path>` | `hg cat -r <rev> <path>` | Retrieve file content at revision |
| `git status --porcelain` | `hg status` (with flags) | Porcelain-style status not needed; parse raw HG output |
| `git blame --porcelain` | `hg annotate --user --number --changeset --date --line-number --template json` | JSON template gives structured per-line records; see `lua/hgsigns/git/blame.lua` |
| `git ls-files --stage` | `hg status` | Used to enumerate tracked/added/removed files |
| `git diff --diff-filter=R …` | `hg status --copies …` | Rename detection; used in `diff_rename_status()` |
| `git cat-file -t <sha>` | _(dropped)_ | Object-type checks were part of the staging path; removed (section 4) |
| `git hash-object` | _(dropped)_ | Part of the staging/index-write path; removed (section 4) |
| `git apply --cached` | _(dropped)_ | Part of the staging/index-write path; removed (section 4) |

### Revision Notation

| Git | Mercurial |
|---|---|
| `HEAD` | `.` (working-copy parent) |
| `HEAD~1` | `.~1` or `parent(.)` |
| `HEAD^` | `.^` |
| `<sha>` | `<node>` (40-char hash or short hash) |

Bare `~` / `^` relative refs must be normalized for Mercurial. Mercurial
revision-facing actions default to `.` instead of `HEAD`.

---

## 4. Removed Subsystems

Several Git-only subsystems have **no Mercurial equivalent** and were removed
rather than ported. When an upstream commit touches any of these, **drop those
hunks** — do not forward-port the Git logic and do not invent an hg substitute.

### Staging area / index

Mercurial has no staging area, so the entire staging surface was dropped:

| Removed surface | Was in upstream | Reason removed |
|---|---|---|
| `stage_hunk()` | `lua/gitsigns/actions.lua` | No staging area in Mercurial |
| `undo_stage_hunk()` | `lua/gitsigns/actions.lua` | Same |
| `stage_buffer()` | `lua/gitsigns/actions.lua` | Same |
| `reset_buffer_index()` | `lua/gitsigns/actions.lua` | Same |
| `signs_staged` config block | `lua/gitsigns/config.lua` | Staged signs require staging; removed with it |
| `signs_staged_enable` config | `lua/gitsigns/config.lua` | Same |
| `_on_attach_pre` hook | `lua/gitsigns/config.lua` | Used only to feed staged status; removed |
| Writable index-edit diff path | `lua/gitsigns/git/repo.lua` | `stage_lines` / `update_index` write-back; removed |
| `git hash-object`, `git apply --cached`, `git cat-file -t` | `lua/gitsigns/git/repo.lua` | Index plumbing for the staging path |

The removal is validated at runtime by `test/cleanup_spec.lua`, which asserts
that `require('hgsigns').stage_hunk == nil` (and the other staging actions),
that `:Hgsigns stage_hunk` / `:Hgsigns stage_buffer` are not valid commands,
and that `config.signs_staged` / `config.signs_staged_enable` are `nil`.

### Other Git-only surfaces with no hg equivalent

| Removed surface | Was in upstream | Reason removed |
|---|---|---|
| Git worktree handling | `lua/gitsigns/git/repo.lua` | Mercurial has no Git-style linked worktrees |
| CRLF / index EOL handling | `lua/gitsigns/git/repo.lua` | Git index concept tied to the staging path |
| GitHub remote URL integration | `lua/gitsigns/git/repo.lua` | Git-hosting-specific feature |

> **Note.** The Git implementations of these subsystems (worktree resolution,
> CRLF/index handling, the staging/index-write plumbing) have been removed from
> this branch — `lua/hgsigns/git/repo.lua` has no `get_info_git`, worktree, or
> index code. When an upstream commit adds or changes any of these Git-only
> surfaces, drop those hunks; do not re-add the Git logic here.

---

## 5. HG Command Stabilization Flags

Every `hg` invocation goes through `lua/hgsigns/git/cmd.lua`, which is the
single place that builds the argv prefix and environment. You do **not** add
these flags at individual call sites — `cmd.lua` applies them unconditionally.

`hg` commands are built as:

```lua
-- argv prefix
cmd = { 'hg', '--config', 'ui.relative-paths=false' }

-- environment (merged over spec.env)
env = {
  HGPLAIN  = '1',   -- suppress color, verbosity, locale, aliases, extensions output
  LC_ALL   = 'C',   -- force C locale for deterministic output
  LANGUAGE = 'C',   -- same
}
```

**Why `--config ui.relative-paths=false`?** `HGPLAIN=1` does *not* suppress
`ui.relative-paths`.  If a user's `~/.hgrc` sets `relative-paths=true`, every
path returned by `hg status`, `hg diff`, etc. will be relative to the
current working directory instead of the repo root, silently breaking all path
resolution in the plugin.  This flag is therefore baked into the hg prefix in
`cmd.lua`.

When porting upstream code that constructs a Git command, translate it to the
`hg` equivalent (section 3) and route it through `cmd.lua` — the env and
`--config` flag are supplied there automatically.

---

## 6. Test Helper Reference

`test/gs_helpers.lua` provides the scratch-repo scaffolding. For porting work,
use the **Mercurial** helpers:

| Function | Purpose |
|---|---|
| `M.hg_init_scratch()` | Seeds a fresh empty scratch HG repository in the isolated temp root |
| `M.setup_test_hg_repo(opts)` | Seeds the scratch repo and (unless `no_add`) commits `test_file`; supports `branch` and `test_file_text` opts. Analogous to upstream `setup_git_repo()` |
| `M.hg(...)` | Runs an `hg` subcommand inside the scratch repo (applies `HGPLAIN`/`LC_ALL`/`ui.relative-paths=false`). Analogous to upstream `git()` |

When porting tests that call `git(...)` or `setup_git_repo()`, replace them with
the `hg` / `setup_test_hg_repo` variants. The rest of the test scaffold (buffer
setup, sign-assertion helpers, async wait utilities like `expectf`) is shared
and needs no VCS changes. Note also that the spec files retain upstream names —
`test/gitsigns_spec.lua` and `test/gs_helpers.lua` were **not** renamed to
`hgsigns_*`/`hs_*`. Match the existing filenames when adding or porting specs.

---

## 7. Quick Cherry-Pick Checklist

**One commit at a time, tests green before moving on.**

1. Apply the upstream commit with `git cherry-pick -n -x <sha>`.
2. Run `grep -rn 'gitsigns\|Gitsigns\|GitSigns' lua/ plugin/ test/` — fix any
   un-renamed identifiers (use the rename map in section 2).
3. Check whether the diff touches any of the **removed subsystems** in section
   4 (staging/index, worktree, CRLF). Drop those hunks.
4. Check whether the diff adds new `git` CLI calls. **Translate each to its
   Mercurial equivalent** (section 3) and route it through
   `lua/hgsigns/git/cmd.lua` so the stabilization env from section 5 applies.
   Do not leave a `git` invocation in the shipped code — this branch must stay
   Git-free (section 1). A quick `grep -rn "'git'" lua/ test/` after porting
   helps catch leaks.
5. Run `make format-check` — fix any style violations before proceeding.
6. Run `make test` — **all tests must pass** (no new failures vs the
   pre-cherry-pick baseline).  If a test fails, fix the code now; do not
   move on to the next commit until the suite is clean.
7. Commit with a message referencing the upstream SHA:
   `git commit -m "port: <subject> (upstream <short-sha>)"`
8. Update `UPSTREAM-CHERRYPICKS.md` — change the row status from `pending` to
   `ported` (or `partial` with a note if you modified or dropped hunks).
9. Only then move on to the next upstream commit.

---

## 8. Keeping the Upstream Mirror Branch Current

Before evaluating new upstream commits, update the dedicated sibling `main/`
worktree to match `upstream/main`.

Do this work in the `main/` worktree directory itself, not in `mercurial/`.
In this repository layout, `mercurial/` is the fork branch worktree and
`../main/` is the upstream mirror worktree.

If you use Worktrunk, switch into the sibling `main/` worktree first instead of
running the merge from `mercurial/`:

```bash
wt switch main
git pull --ff-only upstream main
wt switch mercurial
```

`wt switch main` changes your shell into the existing `main/` worktree. Run the
fast-forward there, then switch back to the fork worktree with
`wt switch mercurial` (or `wt switch -` to return to the previous worktree).

Worktrunk does not provide a dedicated "fast-forward this branch from
upstream/main" command. `wt merge` is for merging the current branch into a
target branch (usually the default branch), which is the opposite direction of
what we want here. Use `wt switch main` to enter the correct worktree, then use
plain Git to update that checkout from `upstream/main`.

```bash
# In the sibling main/ worktree
git checkout main
git pull --ff-only upstream main

# Return to the mercurial worktree when done
git checkout mercurial
```

Example from the `mercurial/` worktree parent directory:

```bash
cd ../main
git checkout main
git pull --ff-only upstream main
```

Do not run the fast-forward from `mercurial/`; use the separate `main/`
worktree so the upstream mirror branch is updated in its own checkout.

---

## 9. Upstream Cherry-Pick Log

All upstream commits that have been evaluated — including ones deliberately
skipped or deferred — are tracked in `UPSTREAM-CHERRYPICKS.md`.

Before starting a new porting session:

```bash
# In the sibling main/ worktree, update the local main mirror
git checkout main
git pull --ff-only upstream main

# Back in mercurial/, check what upstream has that we don't
git log HEAD..upstream/main --oneline

# Check what we've already evaluated (ported, skipped, or deferred)
# by opening UPSTREAM-CHERRYPICKS.md and comparing SHAs
```

When evaluating a new batch, add a dated section to `UPSTREAM-CHERRYPICKS.md`
with every commit's status and notes **before** starting work.  Then work
through the list strictly one commit at a time — run `make test` after each
cherry-pick and commit only when the suite is clean.
