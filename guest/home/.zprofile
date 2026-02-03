# Ensure current directory is readable
[[ -r "$PWD" ]] || cd "$HOME"

# Add ~/.local/bin for Claude Code
export PATH="$HOME/.local/bin:$PATH"

# Load user configuration
[[ -f "$HOME/user/.zprofile" ]] && source "$HOME/user/.zprofile"
