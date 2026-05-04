---
name: port-upstream
description: Port one or more upstream gitsigns.nvim commits into the hgsigns.nvim mercurial branch. Evaluates each commit, applies the rename map and hg translation, drops removed subsystems, runs make format-check and make test after every cherry-pick, and commits on green. Use when asked to "port upstream", "cherry-pick upstream changes", "sync with upstream", or "bring in upstream commits".
---

<objective>
Cherry-pick upstream gitsigns.nvim commits into the hgsigns mercurial branch one at a time, applying the rename map and VCS translation from PORTING.md, running make format-check + make test after each, committing on green, and recording the result in UPSTREAM-CHERRYPICKS.md.
</objective>

<essential_principles>
**One commit at a time.** Never batch-apply a range. Each commit must be individually verified before moving to the next.

**Tests must be green before committing.** If make test introduces new failures, fix them now. Do not commit with known failures.

**Record every decision.** Every commit must be logged in UPSTREAM-CHERRYPICKS.md as ported / partial / skipped / deferred with a reason.

**Rename map is mandatory.** Every occurrence of gitsigns/Gitsigns/GitSigns in runtime identifiers must be renamed. See the table below.

**Drop removed subsystems silently.** Staging area (index/staged hunks), worktree support, CRLF, index-edit path — drop these hunks without logging them as errors.

**Wrap every new hg call.** Any new `hg` invocation must include `HGPLAIN=1`, `LC_ALL=C`, and `--config ui.relative-paths=false`.
</essential_principles>

<rename_map>
| gitsigns (upstream) | hgsigns (this fork) |
|---------------------|---------------------|
| `lua/gitsigns/` | `lua/hgsigns/` |
| `require('gitsigns')` | `require('hgsigns')` |
| `:Gitsigns` | `:Hgsigns` |
| `Gitsigns*` highlight groups | `Hgsigns*` |
| `b:gitsigns_*` buffer vars | `b:hgsigns_*` |
| `User GitsignsUpdate` autocommand | `User HgsignsUpdate` |
| `gitsigns-blame` filetype | `hgsigns-blame` |
| `GitSignsBlameColor*` | `HgsignsBlameColor*` |
</rename_map>

<removed_subsystems>
Drop hunks that touch any of these — they do not exist in hgsigns:
- Staging area / index hunks (`hunks_staged`, `stage_hunk`, `reset_hunk` index path, `undo_stage_hunk`)
- Worktree support (`git worktree`, `core.worktree`, `GIT_WORK_TREE`)
- CRLF / line-ending normalization
- Index-edit path (`edit_from_staging`)
- `signs_staged` / `signs_staged_enable` config options
</removed_subsystems>

<process>
## Step 1 — Identify commits to port

```bash
git fetch upstream
git log HEAD..upstream/main --oneline --reverse
```

If the user specified particular SHAs, use those. Otherwise present the list and ask which to port (or port all in order).

## Step 2 — Read PORTING.md

Read the full `PORTING.md` before starting. It contains the definitive VCS translation table (§3), removed subsystems list (§4), hg stabilization env (§5), and the porting checklist (§7). Reference it throughout.

## Step 3 — For each commit (oldest first)

### 3a. Inspect the commit

```bash
git show <sha> --stat
git show <sha>
```

Classify it as one of:
- **mechanical rename** — only identifier changes, apply directly
- **logic change** — needs VCS translation and/or subsystem dropping
- **test-only** — translate `git()`→`hg()` helpers, `setup_test_repo`→`setup_test_hg_repo`, branch `main`→`default`
- **ci/docs/build** — usually safe to port mechanically
- **git-specific** — skip (e.g. worktree, CRLF, `GIT_DIR` redirects)
- **deferred** — complex harness rewrite; log and skip for now

### 3b. Stage the cherry-pick (do NOT commit yet)

```bash
git cherry-pick -n -x <sha>
```

### 3c. Apply transformations

1. Apply the rename map to all changed files.
2. Drop hunks touching removed subsystems.
3. Translate `git` CLI calls to `hg` equivalents (see PORTING.md §3).
4. Wrap new `hg` calls with `HGPLAIN=1 LC_ALL=C --config ui.relative-paths=false`.
5. In test files: replace `helpers.git()`→`helpers.hg()`, `setup_test_repo`→`setup_test_hg_repo`, expected branch `'main'`→`'default'`, add `-u tester` to `hg commit` calls.

### 3d. Format check

```bash
make format-check
```

If it fails, run `make format` then re-check.

### 3e. Run tests

```bash
make test
```

**All tests must pass.** If new failures appear:
- Fix the code (not the tests, unless the test itself is the wrong thing).
- Re-run until green.
- Only skip/defer if the failure is provably caused by a removed subsystem that cannot be replicated in hg — in that case delete the test and document why.

### 3f. Commit

```bash
git commit -m "port: <upstream subject line> (upstream <short-sha>)"
```

Use the upstream subject verbatim (with `port:` prefix). Add a body paragraph if transformations were non-trivial.

### 3g. Update UPSTREAM-CHERRYPICKS.md

Add a row to the current evaluation table:

```
| `<sha>` | <subject> | ported | <brief note if non-trivial, else blank> |
```

Use `partial` if hunks were dropped, `skipped` if not ported, `deferred` if blocked.

### 3h. Commit the tracking update

```bash
git add UPSTREAM-CHERRYPICKS.md
git commit -m "docs: record upstream <sha> in CHERRYPICKS"
```

## Step 4 — After all commits

Run the full suite one final time:

```bash
make format-check
make test
```

Report: how many ported, how many skipped/deferred, final test count.
</process>

<vcs_translation>
Common git → hg translations (see PORTING.md §3 for the full table):

| git command | hg equivalent |
|-------------|---------------|
| `git log --format=...` | `hg log -T '{template}'` |
| `git show <sha>:<path>` | `hg cat -r <sha> <path>` |
| `git diff <sha>^..<sha>` | `hg diff -c <sha>` |
| `git rev-parse HEAD` | `hg id -i` |
| `git blame -p` | `hg annotate --template json ...` |
| `git ls-files` | `hg status -c` |
| `git stash` | `hg shelve` |
| branch `main` | branch `default` |
</vcs_translation>

<test_translation>
When translating test files:

- `helpers.git('add', f)` → `helpers.hg('add', f)`
- `helpers.git('commit', '-m', msg)` → `helpers.hg('commit', '-m', msg, '-u', 'tester')`
- `helpers.setup_test_repo(opts)` → `helpers.setup_test_hg_repo(opts)`
- `status = { head = 'main', ... }` → `status = { head = 'default', ... }`
- `async.run(...):wait()` for blame → `async.run(...):raise_on_error()` + `vim.wait(5000, ...)`
- Drop tests that assert on `cache.hunks_staged` — delete them (staging removed)
</test_translation>

<success_criteria>
Each commit is done when:
- [ ] `make format-check` exits 0
- [ ] `make test` exits 0 with no new failures vs pre-cherry-pick baseline
- [ ] Commit message starts with `port: ` and ends with `(upstream <sha>)`
- [ ] UPSTREAM-CHERRYPICKS.md row added and committed

Session is done when all target commits are processed and final `make test` is green.
</success_criteria>
