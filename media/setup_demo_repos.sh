#!/usr/bin/env bash
# Sets up throwaway hg repos used by the VHS recordings.
# Re-runnable: blows away and recreates each time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$SCRIPT_DIR/demo_repos"
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"

# ── helpers ─────────────────────────────────────────────────────────────────
hg_init() {
  local dir="$1"
  mkdir -p "$dir"
  hg init "$dir"
  cat > "$dir/.hg/hgrc" <<EOF
[ui]
username = Demo User <demo@example.com>
EOF
}

hg_commit() {
  local dir="$1"; shift
  hg --cwd "$dir" commit -d "2024-01-01 12:00 +0000" -m "$@"
}

# ── demo-hunks: Lua file with add/change/delete hunks ───────────────────────
HUNKS="$DEMO_DIR/hunks"
hg_init "$HUNKS"

cat > "$HUNKS/highlights.lua" <<'EOF'
---@brief Highlight group definitions for hgsigns.

local M = {}

---@type table<string, vim.api.keyset.highlight>
M.groups = {
  HgsignsAdd            = { link = 'DiffAdd' },
  HgsignsChange         = { link = 'DiffChange' },
  HgsignsDelete         = { link = 'DiffDelete' },
  HgsignsTopdelete      = { link = 'DiffDelete' },
  HgsignsChangedelete   = { link = 'DiffChange' },
  HgsignsUntracked      = { link = 'DiffAdd' },
  HgsignsAddNr          = { link = 'HgsignsAdd' },
  HgsignsChangeNr       = { link = 'HgsignsChange' },
  HgsignsDeleteNr       = { link = 'HgsignsDelete' },
  HgsignsAddLn          = { link = 'HgsignsAdd' },
  HgsignsChangeLn       = { link = 'HgsignsDiffChange' },
}

--- Apply all highlight groups to the current colorscheme.
---@param force? boolean Re-apply even if already applied.
function M.apply(force)
  if M._applied and not force then
    return
  end
  for name, def in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, def)
  end
  M._applied = true
end

--- Reset highlight groups back to defaults.
function M.reset()
  M._applied = false
  M.apply(true)
end

return M
EOF

hg --cwd "$HUNKS" add highlights.lua
hg_commit "$HUNKS" "Initial commit"

# Now make add/change/delete edits
cat > "$HUNKS/highlights.lua" <<'EOF'
---@brief Highlight group definitions for hgsigns.
---@module 'hgsigns.highlights'

local M = {}

--- Resolve a highlight group, preferring `primary` if it exists.
---@param primary string
---@param fallback string
---@return string
local function prefer(primary, fallback)
  return vim.fn.hlexists(primary) == 1 and primary or fallback
end

---@type table<string, vim.api.keyset.highlight>
M.groups = {
  HgsignsAdd            = { link = prefer('GitSignsAdd',    'DiffAdd') },
  HgsignsChange         = { link = prefer('GitSignsChange', 'DiffChange') },
  HgsignsDelete         = { link = prefer('GitSignsDelete', 'DiffDelete') },
  HgsignsTopdelete      = { link = 'DiffDelete' },
  HgsignsChangedelete   = { link = 'DiffChange' },
  HgsignsUntracked      = { link = 'DiffAdd' },
  HgsignsAddNr          = { link = 'HgsignsAdd' },
  HgsignsChangeNr       = { link = 'HgsignsChange' },
  HgsignsDeleteNr       = { link = 'HgsignsDelete' },
  HgsignsAddLn          = { link = 'HgsignsAdd' },
  HgsignsChangeLn       = { link = 'HgsignsDiffChange' },
  HgsignsCurrentLineBlame = { link = 'Comment' },
}

--- Apply all highlight groups to the current colorscheme.
---@param force? boolean Re-apply even if already applied.
function M.apply(force)
  if M._applied and not force then
    return
  end
  for name, def in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, def)
  end
  M._applied = true
end

return M
EOF

echo "hunks repo ready: $HUNKS/highlights.lua"

# ── demo-blame: Lua file with multi-author history ───────────────────────────
BLAME="$DEMO_DIR/blame"
hg_init "$BLAME"

cat > "$BLAME/manager.lua" <<'EOF'
---@brief Buffer attachment manager.

local async  = require('hgsigns.async')
local cache  = require('hgsigns.cache')
local signs  = require('hgsigns.signs')

local M = {}

--- Attach hgsigns to a buffer.
---@param bufnr integer
function M.attach(bufnr)
  if cache.get(bufnr) then
    return
  end
  cache.set(bufnr, { bufnr = bufnr })
  signs.update(bufnr)
end
EOF

hg --cwd "$BLAME" add manager.lua
hg --cwd "$BLAME" commit -d "2023-06-01 09:00 +0000" -u "Alice <alice@example.com>" \
  -m "feat: Initial buffer attachment manager"

cat >> "$BLAME/manager.lua" <<'EOF'

--- Detach hgsigns from a buffer and clean up state.
---@param bufnr integer
function M.detach(bufnr)
  local entry = cache.get(bufnr)
  if not entry then
    return
  end
  signs.remove(bufnr)
  cache.del(bufnr)
end

--- Return true if hgsigns is attached to the given buffer.
---@param bufnr integer
---@return boolean
function M.is_attached(bufnr)
  return cache.get(bufnr) ~= nil
end
EOF

hg --cwd "$BLAME" commit -d "2023-09-15 14:30 +0000" -u "Bob <bob@example.com>" \
  -m "feat: Add detach and is_attached helpers"

cat >> "$BLAME/manager.lua" <<'EOF'

--- Re-attach all currently attached buffers (e.g. after config reload).
function M.reattach_all()
  for bufnr in cache.iter() do
    M.detach(bufnr)
    async.run(function()
      M.attach(bufnr)
    end)
  end
end
EOF

hg --cwd "$BLAME" commit -d "2023-12-20 11:00 +0000" -u "Carol <carol@example.com>" \
  -m "feat: Add reattach_all for config-reload support"

cat >> "$BLAME/manager.lua" <<'EOF'

return M
EOF

hg --cwd "$BLAME" commit -d "2024-03-10 16:45 +0000" -u "Demo User <demo@example.com>" \
  -m "chore: Export module table"

echo "blame repo ready: $BLAME/manager.lua"
echo "Done."
