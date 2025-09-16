# .zshrc

#export PROMPT="%n@%m %~ %# "
export PROMPT="%F{magenta}%n %F{blue}%~%f %# "

autoload -Uz +X compinit && compinit

# Case insensitive tab completion
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'

# auto-fill the first viable candidate for tab completion
setopt menucomplete

# vi-editing on command line and for files
bindkey -v
export EDITOR=vi

# Fix zsh bug where tab completion hangs on git commands
# https://superuser.com/a/459057
__git_files () {
    _wanted files expl 'local files' _files
}

# Only allow unique entries in path
typeset -U path

# utilities
command -v bat &>/dev/null && alias cat='bat --paging=never'
command -v direnv &>/dev/null && eval "$(direnv hook zsh)"

# ls
if command -v eza &>/dev/null ; then
    alias ls=eza
    alias l='ls -l --git'
    alias li='ls -l --git --git-ignore'
    alias ll='ls -al --git'
    alias lli='ls -al --git --git-ignore'
    alias tree='ls -lT --git'
else
    alias l='ls -l'
    alias ll='ls -al'
fi

# Perform sandvault setup
"$HOME/configure"

# Use GNU CLI binaries over outdated OSX CLI binaries
if command -v brew &>/dev/null ; then
    BREW_PREFIX="$(brew --prefix)"
    if [[ -d "$BREW_PREFIX/opt/coreutils/libexec/gnubin" ]]; then
        export PATH="$BREW_PREFIX/opt/coreutils/libexec/gnubin:$PATH"
    fi
    if [[ -d "$BREW_PREFIX/opt/findutils/libexec/gnubin" ]]; then
        export PATH="$BREW_PREFIX/opt/findutils/libexec/gnubin:$PATH"
    fi
    if [[ -d "$BREW_PREFIX/opt/gnu-getopt/bin" ]]; then
        export PATH="$BREW_PREFIX/opt/gnu-getopt/bin:$PATH"
    fi
    if [[ -d "$BREW_PREFIX/opt/python/libexec/bin" ]]; then
        export PATH="$BREW_PREFIX/opt/python/libexec/bin:$PATH"
    fi
fi

# Add clodpod and user bin directories
export PATH="$HOME/bin:$PATH"
if [[ -d "$HOME/user/bin" ]]; then
    export PATH="$HOME/user/bin:$PATH"
fi


###############################################################################
# Create symbolic links for all projects
###############################################################################
# Wait until install.sh has installed coreutils with homebrew
# so we can use the simpler/easier/better homebrew ln tool
LN="$(brew --prefix)/opt/coreutils/libexec/gnubin/ln"
if [[ -x "$LN" ]]; then
    mkdir -p "/Users/clodpod/projects"
    fd -t d --max-depth 1 . "/Volumes/My Shared Files" -0 | \
        xargs -0 "$LN" -sf --target "/Users/clodpod/projects"
fi


###############################################################################
# Load user configuration
###############################################################################
[[ -f "$HOME/user/.zshrc" ]] && source "$HOME/user/.zshrc"


###############################################################################
# Set active project
###############################################################################
PROJECT="${PROJECT:-project}"
PROJECT_DIR="$HOME/projects/$PROJECT"
if [[ -d "$PROJECT_DIR" ]]; then
    cd "$PROJECT_DIR"
    # If INITIAL_DIR is set, navigate to the subdirectory within the project
    if [[ -n "${INITIAL_DIR:-}" ]] && [[ -d "$PROJECT_DIR/$INITIAL_DIR" ]]; then
        cd "$PROJECT_DIR/$INITIAL_DIR"
    fi
fi

# Run specified application
if [[ "${COMMAND:-}" != "" ]]; then
    exec "$COMMAND"
fi
