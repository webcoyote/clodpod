# Ensure current directory is readable
[[ -r "$PWD" ]] || cd "$HOME"

# Add ~/.local/bin for Claude Code
export PATH="$HOME/.local/bin:$PATH"

# Load user configuration
if [[ -f "$HOME/user/.zprofile" ]]; then
    source "$HOME/user/.zprofile"
fi
