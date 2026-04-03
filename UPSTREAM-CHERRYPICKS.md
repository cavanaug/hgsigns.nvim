# Upstream Cherry-Pick Log

Tracks every upstream [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)
commit we have evaluated, and what we did with it.

**Upstream remote:** `upstream` → `https://github.com/lewis6991/gitsigns.nvim`
**Our branch:** `mercurial`

Statuses:
- `ported` — applied, renamed, committed as `port: … (upstream <sha>)`
- `partial` — applied with modifications noted below
- `skipped` — deliberately not ported; reason given
- `pending` — evaluated, queued for porting
- `deferred` — worth doing later, not urgent

---

## 2026-04-03 — upstream/main @ `944ef13`

Upstream HEAD at time of evaluation: `944ef13` (2026-04-03)
Our HEAD at time of evaluation: `49aad3c` (2026-04-03)

| SHA | Subject | Status | Notes |
|-----|---------|--------|-------|
| `c5480c0` | fix(uv): do not rely on gc to cleanup handles | ported | Dropped `w_crlf` lines (already removed); `ls_tree` assert tightening and `file_info` simplification applied cleanly; test file changes skipped (git-specific helpers) |
| `1189caf` | fix(watcher): fall back to fs_poll on fs_event failure | pending | Translate `_fs_poll_targets()` — upstream watches `gitdir/HEAD`, `gitdir/index`, `commondir/packed-refs`; ours should watch `.hg/dirstate`, `.hg/branch`, `.hg/bookmarks` |
| `e1b90b6` | build(emmylua): bump analyzer to 0.22.0 | pending | Mechanical Makefile bump + remove now-unnecessary casts |
| `9a64d19` | fix(diff): avoid false EOF hunk markers | ported | Rename only — `>=` → `>` in two `no_nl_at_eof` conditions in `diff_int.lua` |
| `733b0f6` | fix(watcher): preserve alternate buffers on rename | ported | `delete_alt()` → `delete_old_name_buffer()` in `util.lua`; new test translated to hg (`hg mv`, `setup_test_hg_repo`) |
| `909f154` | fix(stage): keep add hunks undoable | pending | Apply `hunks.lua` one-line removal only; skip `actions_spec.lua` (staging test) |
| `720c6fc` | fix(qflist): tolerate nil attached hunks | ported | Rename only — replace `assert(bcache.hunks)` with nil guard in `qflist.lua` |
| `fca7a4b` | fix(actions): repair show_commit history | ported | `<C-o>/<C-i>` history pointer fix in `show_commit.lua`; `modify/delete` conflict resolved by removing stray `lua/gitsigns/` copy |
| `e5c4b72` | fix(qflist): include tracked deletions in all list | pending | `repo.lua` `deleted` flag is clean; `qflist.lua` uses `:0:` Git staging notation — review against our `hg cat` equivalent before applying |
| `21018b0` | fix(hunks): apply zero-count hunks at insert point | ported | Rename only — two-line logic fix in `hunks.lua` |
| `944ef13` | fix(statuscolumn): render signs in live statuscolumn | ported | Rename only — resolve `bufnr=0` + set `statuscolumn_active` in `manager.lua` |
| `e1fb542` | test(harness): trim redundant waits | deferred | Test timing tweaks only; low priority |
| `a655548` | test(gitsigns): tolerate extra vimgrep path messages | deferred | Test assertion loosening only; low priority |
| `87b7902` | ci(test): speed up the functional suite | deferred | Take Makefile/gitignore additions only; skip CI YAML and test sleep changes |
| `d1e88d7` | test(scratch): isolate repos and seed scratch copies | deferred | Major `gs_helpers.lua` rewrite; needs full hg translation of scratch repo seeding |
