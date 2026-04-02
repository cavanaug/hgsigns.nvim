# hgsigns_actions.tape — records hunk navigation and preview demo

Output media/hgsigns_actions.gif

Require nvim
Require hg

Set Shell "bash"
Set FontSize 14
Set Width 900
Set Height 550
Set Theme "Catppuccin Mocha"
Set TypingSpeed 80ms
Set Padding 0

# ── Setup: open the demo file (hidden) ──────────────────────────────────────
Hide
Type "cd /home/cavanaug/wip_other/projects/hgsigns_v2/gitsigns.nvim/mercurial"
Enter
Type "nvim -u media/demo_init.lua media/demo_repos/hunks/demo.py"
Enter
Sleep 2s
# Jump to top of file and wait for signs to load
Type "gg"
Sleep 1.5s
Show

# ── Signs visible — give viewer a moment to absorb ──────────────────────────
Sleep 1.5s

# Navigate to first change hunk
Type "]h"
Sleep 800ms
Type "]h"
Sleep 800ms

# Preview hunk popup
Type " hp"
Sleep 1.5s

# Close popup
Escape
Sleep 600ms

# Navigate to a delete hunk
Type "]h"
Sleep 800ms

# Preview inline
Type " hi"
Sleep 1.5s

# Navigate to added section
Type "]h"
Sleep 800ms
Type "]h"
Sleep 600ms

# Reset a hunk (undo one change)
Type " hr"
Sleep 1s

# Navigate back
Type "[h"
Sleep 600ms
Type "[h"
Sleep 600ms

Sleep 1s
