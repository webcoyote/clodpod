# Ensure current directory is readable
[[ -r "$PWD" ]] || cd "$HOME"

# Load user configuration
if [[ -f "$HOME/user/.zlogout" ]]; then
    source "$HOME/user/.zlogout"
fi
