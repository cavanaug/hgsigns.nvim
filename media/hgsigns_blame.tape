# hgsigns_blame.tape — records current-line blame virtual text + blame window

Output media/hgsigns_blame.gif

Require nvim
Require hg

Set Shell "bash"
Set FontSize 14
Set Width 900
Set Height 550
Set Theme "Catppuccin Mocha"
Set TypingSpeed 80ms
Set Padding 0

# ── Setup: open blame demo file (hidden) ────────────────────────────────────
Hide
Type "cd /home/cavanaug/wip_other/projects/hgsigns_v2/gitsigns.nvim/mercurial"
Enter
Type "nvim -u media/demo_init.lua media/demo_repos/blame/server.py"
Enter
Sleep 2.5s
Type "gg"
Sleep 1.5s
Show

# ── Blame virtual text visible — move cursor down line by line ───────────────
Sleep 1s

# Scroll through lines to show different authors in the blame virtual text
Type "j"
Sleep 400ms
Type "j"
Sleep 400ms
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

# Show inline popup blame for current line
Type " gb"
Sleep 2s

# Close popup
Escape
Sleep 500ms

# Jump further down
Type "20G"
Sleep 600ms
Type "j"
Sleep 400ms
Type "j"
Sleep 400ms
Type "j"
Sleep 400ms

# Open the full blame window
Type ":Hgsigns blame"
Enter
Sleep 2.5s

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
