# hgsigns_blame.tape — current-line blame virtual text + blame window demo
# Uses full LazyVim config (sonokai colorscheme, snacks statuscolumn, etc.)

Output media/hgsigns_blame.gif

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

# ── Setup: open blame demo file via full LazyVim config (hidden) ─────────────
Hide
Type "cd /home/cavanaug/wip_other/projects/hgsigns_v2/gitsigns.nvim/mercurial"
Enter
Type "find ~/.local/state/nvim/swap -name '*demo_repos*' -delete 2>/dev/null; true"
Enter
Type "nvim --cmd 'set noswapfile' -c 'lua vim.defer_fn(function() vim.diagnostic.config({virtual_text=false,signs=false,underline=false}) end,3000)' media/demo_repos/blame/manager.lua"
Enter
Sleep 5s
# Dismiss any startup prompts, then move to top
Enter
Sleep 300ms
Type "gg"
Sleep 1s
# Enable current line blame for this session
Type ":Hgsigns toggle_current_line_blame"
Enter
Sleep 1s
Show

# ── Navigate lines — blame virtual text updates per line ─────────────────────
Sleep 1s

Type "j"
Sleep 400ms
Type "j"
Sleep 400ms
Type "j"
Sleep 400ms
Type "j"
Sleep 400ms
Type "j"
Sleep 500ms
Type "j"
Sleep 500ms
Type "j"
Sleep 600ms
Type "j"
Sleep 600ms
Type "j"
Sleep 600ms
Type "j"
Sleep 600ms

# Blame line popup  (<leader>ghb with space leader)
Type " ghb"
Sleep 2.5s

# Close popup
Escape
Sleep 600ms

# Open the full blame window  (<leader>ghB)
Type " ghB"
Sleep 3s

# Navigate in blame window
Type "j"
Sleep 300ms
Type "j"
Sleep 300ms
Type "j"
Sleep 300ms
Type "j"
Sleep 300ms
Type "j"
Sleep 300ms
Type "j"
Sleep 300ms

Sleep 1.5s
