# Porting Guide: gitsigns.nvim → hgsigns.nvim

This document is for maintainers who want to cherry-pick upstream
[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) commits into this
Mercurial fork.  Everything here was established during the initial port; the
decisions referenced below live in `.gsd/DECISIONS.md`.

---

## 1. Fork Anchor and Rename Strategy

The fork was performed as a **rename-first** operation (D002):

- The very first commit in this repository renames every `gitsigns`/`Gitsigns`/
  `GitSigns` identifier to its `hgsigns`/`Hgsigns` equivalent, with no VCS
  logic changed.
- All subsequent commits layer in Mercurial backend logic on top of that clean
  rename baseline.

When cherry-picking upstream fixes, diff the upstream commit against this
rename anchor to separate structural identifier changes from logic changes.
Conflicts that touch only identifiers are almost always mechanical; conflicts
that touch VCS command arguments require more care (see sections 3–4 below).

---

## 2. Module and Runtime Rename Map

| gitsigns (upstream) | hgsigns (this fork) |
|---|---|
| `lua/gitsigns/` | `lua/hgsigns/` |
| `require('gitsigns')` | `require('hgsigns')` |
| `require('gitsigns.foo')` | `require('hgsigns.foo')` |
| `:Gitsigns <action>` | `:Hgsigns <action>` |
| Highlight group `Gitsigns*` | `Hgsigns*` (D005) |
| Highlight group `GitSigns*` | `Hgsigns*` (D005) |
| Buffer variable `b:gitsigns_*` | `b:hgsigns_*` |
| Autocommand event `User GitsignsUpdate` | `User HgsignsUpdate` |
| Lua type prefix `Gitsigns.` | `Hgsigns.` |
| Config key `gitsigns` (e.g. in statusline helpers) | `hgsigns` |

> **Rule of thumb (D005):** every runtime identifier — commands, events,
> augroups, filetypes, URI schemes, highlight group prefixes — uses the single
> lowercase project name `hgsigns` / title-case `Hgsigns`.  The upstream dual
> spellings (`Gitsigns` *and* `GitSigns`) are collapsed into one.

---

## 3. VCS Command Translation Table

The Mercurial equivalents used in `lua/hgsigns/git/` are listed below.  The
HG commands are always run with the stabilization environment described in
section 5.

| Git command (upstream) | Mercurial equivalent (this fork) | Notes |
|---|---|---|
| `git rev-parse --show-toplevel` | `hg root` | Returns repo root path |
| `git rev-parse HEAD` | `hg parents --template {node}` | Full 40-char node hash |
| `git diff [--name-status] [base]` | `hg diff [--name-status] [base]` | Git-format diff via `--git` flag where needed |
| `git log --follow …` | `hg log --follow …` | Follow renames across revisions |
| `git show <rev>:<path>` | `hg cat -r <rev> <path>` | Retrieve file content at revision |
| `git status --porcelain` | `hg status` (with flags) | Porcelain-style status not needed; parse raw HG output |
| `git blame --porcelain` | `hg annotate --user --number --changeset --date --line-number --template json` (D003) | JSON template gives structured per-line records; see `lua/hgsigns/git/blame.lua` |
| `git ls-files --stage` | `hg status` | Used to enumerate tracked/added/removed files |
| `git diff --diff-filter=R …` | `hg status --copies …` | Rename detection; used in `diff_rename_status()` |
| `git cat-file -t <sha>` | _(no equivalent needed)_ | Object-type checks were removed with staging |
| `git hash-object` | _(removed)_ | Part of staging subsystem; see section 4 |
| `git apply --cached` | _(removed)_ | Part of staging subsystem; see section 4 |

### Revision Notation

| Git | Mercurial |
|---|---|
| `HEAD` | `.` (working-copy parent) |
| `HEAD~1` | `.~1` or `parent(.)` |
| `HEAD^` | `.^` |
| `<sha>` | `<node>` (40-char hash or short hash) |

Bare `~` / `^` relative refs must be normalized against the active VCS
(see D020).  The fork defaults Mercurial revision-facing actions to `.`
instead of `HEAD`.

---

## 4. Removed Subsystems

The following Git-only subsystems were **removed entirely** — not stubbed,
not replaced with Mercurial equivalents (D004, D029).

| Removed surface | Was in upstream | Reason removed |
|---|---|---|
| `stage_hunk()` | `lua/gitsigns/actions.lua` | No staging area in Mercurial base workflow |
| `undo_stage_hunk()` | `lua/gitsigns/actions.lua` | Same |
| `stage_buffer()` | `lua/gitsigns/actions.lua` | Same |
| `reset_buffer_index()` | `lua/gitsigns/actions.lua` | Same |
| `signs_staged` config block | `lua/gitsigns/config.lua` | Staged signs require staging; removed with it |
| `_on_attach_pre` hook | `lua/gitsigns/config.lua` | Used only to feed staged status; removed |
| Worktree support | `lua/gitsigns/git/repo.lua` | Mercurial has no Git-style worktrees |
| CRLF handling (`i_crlf`, `w_crlf`) | `lua/gitsigns/git/repo.lua` | Git index concept; removed with staging path |
| GitHub Flavored diff integration | `lua/gitsigns/git/repo.lua` | Git-only remote URL feature |
| Writable index-edit diff path | `lua/gitsigns/git/repo.lua` | `stage_lines` / `update_index`; removed (D029) |

When cherry-picking upstream commits that touch these surfaces, **drop the
diff hunks** — do not attempt to forward-port staging logic.

The removal is validated at runtime by `test/cleanup_spec.lua`, which asserts
that `require('hgsigns').stage_hunk == nil` and that `:Hgsigns stage_hunk`
returns an error.

---

## 5. HG Command Stabilization Flags

Every `hg` invocation in `lua/hgsigns/git/cmd.lua` runs with the following
environment and flags (D001):

```lua
env = {
  HGPLAIN  = '1',   -- suppress color, verbosity, locale, aliases, extensions output
  LC_ALL   = 'C',   -- force C locale for deterministic output
  LANGUAGE = 'C',   -- same
}
args = {
  '--config', 'ui.relative-paths=false',  -- force absolute paths even when cwd is a subdir
  -- ... command-specific args follow
}
```

**Why `--config ui.relative-paths=false`?** `HGPLAIN=1` does *not* suppress
`ui.relative-paths`.  If a user's `~/.hgrc` sets `relative-paths=true`, every
path returned by `hg status`, `hg diff`, etc. will be relative to the
current working directory instead of the repo root, silently breaking all path
resolution in the plugin.  This flag must be passed explicitly on every
invocation.

When porting upstream code that constructs git commands, add this env block and
the `--config` flag to the equivalent `hg` call.

---

## 6. Test Helper Reference

`test/gs_helpers.lua` exports three Mercurial-specific helpers used throughout
the test suite:

| Function | Purpose |
|---|---|
| `hg_init_scratch()` | Creates a fresh scratch HG repository in a temp dir and `cd`s into it |
| `setup_test_hg_repo(opts)` | Calls `hg_init_scratch()` then populates it with tracked files; analogous to the upstream `setup_git_repo()` |
| `hg(...)` | Thin wrapper that runs an `hg` subcommand inside the scratch repo; analogous to the upstream `git()` helper |

When porting tests that call `git(...)` or `setup_git_repo()`, replace with the
`hg`/`setup_test_hg_repo` variants.  The rest of the test scaffold (buffer
setup, sign assertion helpers, async wait utilities) is shared and does not
need changes.

---

## 7. Quick Cherry-Pick Checklist

1. Apply the upstream commit with `git cherry-pick -n <sha>`.
2. Run `grep -r 'gitsigns\|Gitsigns\|GitSigns' lua/ plugin/ test/` — fix any
   un-renamed identifiers (use the rename map in section 2).
3. Check whether the diff touches any of the **removed subsystems** in section
   4.  Drop those hunks.
4. Check whether the diff adds new `git` CLI calls.  Translate them using
   section 3 and wrap them in the stabilization env from section 5.
5. Run `make test` and `make format-check` to verify.
