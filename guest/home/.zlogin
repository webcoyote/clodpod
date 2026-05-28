# Ensure current directory is readable
[[ -r "$PWD" ]] || cd "$HOME"

# Load user configuration
if [[ -f "$HOME/user/.zlogin" ]]; then
    source "$HOME/user/.zlogin"
fi
