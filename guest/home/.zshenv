# Ensure current directory is readable
[[ -r "$PWD" ]] || cd "$HOME"

# Load user configuration
if [[ -f "$HOME/user/.zshenv" ]]; then
    source "$HOME/user/.zshenv"
fi
