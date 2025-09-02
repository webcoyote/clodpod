# Set PATH with $HOME/bin first
export PATH="$HOME/bin:$PATH"

export PROMPT="%n@clodpod-xcode %1~ %# "

# Use GNU CLI binaries over outdated OSX CLI binaries
if command -v brew &>/dev/null ; then
    PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$PATH"
fi

# Add support for GNU getopt
if [[ -x "/opt/homebrew/opt/gnu-getopt/bin" ]]; then
    export PATH="/opt/homebrew/opt/gnu-getopt/bin:$PATH"
fi

# The only reliably cross-platform editor
export EDITOR=vi

# utilities
command -v bat &>/dev/null && alias cat='bat --paging=never'
command -v eza &>/dev/null && alias ls=eza
command -v direnv &>/dev/null && eval "$(direnv hook zsh)"

# ls
alias l='ls -l --git'
alias li='ls -l --git --git-ignore'
alias ll='ls -al --git'
alias lli='ls -al --git --git-ignore'
alias tree='ls -lT --git'

PROJECT_DIR="$HOME/projects/project"
alias project="cd \"$PROJECT_DIR\""
if [[ -d "$PROJECT_DIR" ]]; then
    cd "$PROJECT_DIR"
    "$HOME/bin/claude"
fi

