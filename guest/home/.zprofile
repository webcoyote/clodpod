# Ensure current directory is readable
[[ -r "$PWD" ]] || cd "$HOME"

# Add login bin directory to PATH
[[ -d "$HOME/.login/bin" ]] && export PATH="$HOME/.login/bin:$PATH"

# Load user configuration
[[ -f "$HOME/user/.zprofile" ]] && source "$HOME/user/.zprofile"
