#!/usr/bin/env bash
#set -Eeuo pipefail

# Make sure this file is executable: chmod +x ~/.claude/statusline-command.sh

# Claude Code statusline script - optimized with colors and emojis
# Reads JSON input from stdin and outputs a formatted status line to stdout
# Add to your ~/.claude/settings.json
#
# "statusLine": {
#   "type": "command",
#   "command": "bash ~/.claude/statusline-command.sh"
# }
#
# SYMBOL LEGEND:
# 🤖 Model indicator
# 📁 Current directory
# Git status icons:
#   ✓  Clean repository (green)
#   ⚡ Changes present (yellow)
#   ⚠  Merge conflicts (red)
#   +N Staged files count (green)
#   ~N Modified files count (yellow)
#   ?N Untracked files count (gray)
#   ↑N Commits ahead of remote (green)
#   ↓N Commits behind remote (yellow)
#   ↕N/M Diverged from remote (yellow)
#   PR#N Open pull request number (cyan)
# 🌳 Git worktree indicator
# 🐍 Python virtual environment
# ⬢  Node.js version
# 🐳 Docker environment detected

# Debug mode - set STATUSLINE_DEBUG=1 to see raw values
DEBUG="${STATUSLINE_DEBUG:-0}"

# Color codes for better visual separation
readonly BLUE='\033[94m'      # Bright blue for model/main info
readonly GREEN='\033[92m'     # Bright green for clean git status
readonly YELLOW='\033[93m'    # Bright yellow for modified git status
readonly RED='\033[91m'       # Bright red for conflicts/errors
readonly PURPLE='\033[95m'    # Bright purple for directory
readonly CYAN='\033[96m'      # Bright cyan for python venv
#readonly WHITE='\033[97m'     # Bright white for time
readonly GRAY='\033[37m'      # Gray for separators
readonly RESET='\033[0m'      # Reset colors
readonly BOLD='\033[1m'       # Bold text

# Read JSON input from stdin
input=$(cat)

# Extract data from JSON input using jq
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // "."')

dir_display="$(basename "$current_dir")"

# Get git status and worktree information with enhanced detection
git_info=""
if git -C "$current_dir" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$current_dir" branch --show-current 2>/dev/null)

    # If no branch (detached HEAD), show short commit hash
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$current_dir" rev-parse --short HEAD 2>/dev/null)
        branch="detached:${branch}"
    fi

    # Enhanced worktree detection
    worktree_info=""
    git_dir=$(git -C "$current_dir" rev-parse --git-dir 2>/dev/null)

    # Check if we're in a worktree
    if [[ "$git_dir" == *".git/worktrees/"* ]] || [[ -f "$git_dir/gitdir" ]]; then
        worktree_name=$(basename "$current_dir")
        # Only show worktree indicator if it adds information
        # Don't show if branch name already contains the worktree info
        if [[ "$worktree_name" =~ ^TOK ]] && [[ "$branch" != *"$worktree_name"* ]]; then
            # For TOK worktrees, just show the tree emoji
            worktree_info=" ${CYAN}🌳${RESET}"
        elif [[ ! "$worktree_name" =~ ^TOK ]] && [[ "$branch" != "$worktree_name" ]]; then
            # For other worktrees, just show tree emoji
            worktree_info=" ${CYAN}🌳${RESET}"
        fi
    fi

    if [[ -n "$branch" ]]; then
        # Comprehensive git status check
        # Git status format: XY filename
        # X = status of staging area, Y = status of working tree
        git_status=$(git -C "$current_dir" status --porcelain 2>/dev/null)

        # Count different types of changes (handle empty status gracefully)
        if [[ -n "$git_status" ]]; then
            # Count untracked files (starts with ??)
            untracked=$(echo "$git_status" | grep -c '^??')
            # Count modified files (M in second column or first column with space)
            modified=$(echo "$git_status" | grep -c '^.M\|^ M')
            # Count staged files (non-space in first column, excluding ??)
            staged=$(echo "$git_status" | grep -c '^[ADMR]')
            # Count conflicts (UU, AA, DD)
            conflicts=$(echo "$git_status" | grep -c '^UU\|^AA\|^DD')
        else
            untracked=0
            modified=0
            staged=0
            conflicts=0
        fi

        # Debug output
        if [[ "$DEBUG" == "1" ]]; then
            echo "DEBUG: Git Status Raw:" >&2
            echo "$git_status" >&2
            echo "DEBUG: Counts - Staged:$staged Modified:$modified Untracked:$untracked Conflicts:$conflicts" >&2
        fi

        # Check for ahead/behind status
        ahead_behind=""
        upstream=$(git -C "$current_dir" rev-parse --abbrev-ref '@{u}' 2>/dev/null)
        if [[ -n "$upstream" ]]; then
            ahead=$(git -C "$current_dir" rev-list --count '@{u}..HEAD' 2>/dev/null)
            behind=$(git -C "$current_dir" rev-list --count 'HEAD..@{u}' 2>/dev/null)

            if [[ "$ahead" -gt 0 ]] && [[ "$behind" -gt 0 ]]; then
                ahead_behind=" ${YELLOW}↕${ahead}/${behind}${RESET}"
            elif [[ "$ahead" -gt 0 ]]; then
                ahead_behind=" ${GREEN}↑${ahead}${RESET}"
            elif [[ "$behind" -gt 0 ]]; then
                ahead_behind=" ${YELLOW}↓${behind}${RESET}"
            fi
        fi

        # Check for open PRs using GitHub CLI if available
        pr_info=""
        if command -v gh >/dev/null 2>&1; then
            # Only check for PRs if we're in a GitHub repo
            remote_url=$(git -C "$current_dir" config --get remote.origin.url 2>/dev/null)
            if [[ "$remote_url" == *"github.com"* ]]; then
                # Quick PR check (gh caches this, so it's usually fast after first run)
                pr_number=$(gh pr view --json number -q .number 2>/dev/null)
                if [[ -n "$pr_number" ]]; then
                    pr_info=" ${CYAN}PR#${pr_number}${RESET}"
                fi
            fi
        fi

        # Build status indicators
        status_indicators=""
        if [[ "$conflicts" -gt 0 ]]; then
            git_color="${RED}"
            git_icon="⚠"
            status_indicators="${RED}⚠️ ${conflicts} conflicts${RESET}"
        elif [[ -n "$git_status" ]]; then
            git_color="${YELLOW}"
            git_icon="⚡"

            # Build status string with descriptive text
            status_parts=()
            if [[ "$untracked" -gt 0 ]]; then
                status_parts+=("${GRAY}📄 ${untracked} untracked${RESET}")
            fi
            if [[ "$modified" -gt 0 ]]; then
                status_parts+=("${YELLOW}📝 ${modified} modified${RESET}")
            fi
            if [[ "$staged" -gt 0 ]]; then
                status_parts+=("${GREEN}✅ ${staged} staged${RESET}")
            fi

            # Join status parts with commas
            if [[ ${#status_parts[@]} -gt 0 ]]; then
                status_indicators=$(IFS=", "; echo "${status_parts[*]}")
            fi
        else
            git_color="${GREEN}"
            git_icon="✅"
        fi

        # Construct git info string with separate sections
        git_branch_info="${git_color}${git_icon} ${branch}${RESET}${worktree_info}${ahead_behind}${pr_info}"

        if [[ -n "$status_indicators" ]]; then
            # Has changes - show branch and status in separate sections
            git_info=" ${GRAY}│${RESET} ${git_branch_info} ${GRAY}│${RESET} ${status_indicators}"
        else
            # Clean repository - just show branch
            git_info=" ${GRAY}│${RESET} ${git_branch_info}"
        fi
    fi
fi

# Get Python virtual environment info
venv_info=""
if [[ -n "$VIRTUAL_ENV" ]]; then
    venv_name=$(basename "$VIRTUAL_ENV")
    # Smart truncation for long venv names
    if [[ ${#venv_name} -gt 15 ]]; then
        venv_name="${venv_name:0:12}..."
    fi
    venv_info=" ${GRAY}│${RESET} ${CYAN}🐍${venv_name}${RESET}"
fi

# Get Node.js version if in a Node project
node_info=""
if [[ -f "$current_dir/package.json" ]]; then
    node_version=$(node --version 2>/dev/null | sed 's/v//')
    if [[ -n "$node_version" ]]; then
        # Truncate to major.minor version
        node_version=${node_version%.*}
        node_info=" ${GRAY}│${RESET} ${GREEN}⬢ ${node_version}${RESET}"
    fi
fi

# Build output string with smart separators
output_string=" ${BLUE}🤖${RESET} ${BOLD}${BLUE}${model_name}${RESET} ${GRAY}│${RESET} ${PURPLE}📁${dir_display}${RESET}"

# Add git info if present
[[ -n "$git_info" ]] && output_string="${output_string}${git_info}"

# Add other components with separators only when needed
extra_items=""

# Collect non-empty items
[[ -n "$venv_info" ]] && extra_items="${extra_items} ${venv_info}"
[[ -n "$node_info" ]] && extra_items="${extra_items} ${node_info}"

# Add extra items with separator if there are any
if [[ -n "$extra_items" ]]; then
    output_string="${output_string} ${GRAY}│${RESET}${extra_items}"
fi

# Output the complete string
echo -e "$output_string"
