# hgsigns_actions.tape — hunk navigation and preview demo
# Uses full LazyVim config (sonokai colorscheme, snacks statuscolumn, etc.)

Output media/hgsigns_actions.gif

Require nvim
Require hg

Set Shell "bash"
Set FontSize 14
Set FontFamily "MesloLGS Nerd Font"
Set Width 900
Set Height 550
Set Theme { "background": "#2c2e34", "foreground": "#e2e2e3", "cursor": "#e2e2e3", "cursorAccent": "#2c2e34", "selection": "#3d3f4a" }
Set TypingSpeed 80ms
Set Padding 0

# ── Setup: open the demo file via full LazyVim config (hidden) ───────────────
Hide
Type "cd /home/cavanaug/wip_other/projects/hgsigns_v2/gitsigns.nvim/mercurial"
Enter
Type "find ~/.local/state/nvim/swap -name '*demo_repos*' -delete 2>/dev/null; true"
Enter
Type "nvim --cmd 'set noswapfile' -c 'lua vim.defer_fn(function() vim.diagnostic.config({virtual_text=false,signs=false,underline=false}) end,3000)' media/demo_repos/hunks/highlights.lua"
Enter
Sleep 5s
# Dismiss any startup prompts, then move to top
Enter
Sleep 300ms
Type "gg"
Sleep 1.5s
Show

# ── Signs visible — give viewer a moment to absorb ───────────────────────────
Sleep 1.5s

# Navigate to first change hunk
Type "]h"
Sleep 800ms
Type "]h"
Sleep 800ms

# Preview hunk popup  (<leader>ghp with space leader)
Type " ghp"
Sleep 1.8s

# Close popup
Escape
Sleep 600ms

# Navigate through remaining hunks
Type "]h"
Sleep 800ms
Type "]h"
Sleep 800ms

# Show diffthis split  (<leader>ghd)
Type " ghd"
Sleep 1.8s

# Close diff
Type ":q"
Enter
Sleep 600ms

# Navigate back to top
Type "gg"
Sleep 600ms

Sleep 1s
