
## Per-agent extra arguments

Set these environment variables on the **host** to pass extra flags through to each agent's
wrapper script inside the VM:

| Variable | Agent | Example |
|---|---|---|
| `CLODPOD_CLAUDE_ARGS` | Claude Code | `--remote-control` |
| `CLODPOD_CODEX_ARGS` | OpenAI Codex | `--model o4-mini` |
| `CLODPOD_GEMINI_ARGS` | Google Gemini | `--debug` |

Usage:

    # One-off
    CLODPOD_CLAUDE_ARGS="--remote-control" clod claude

    # Persistent — add to your HOST shell profile (~/.zshrc, ~/.zshenv, etc.)
    # These are host-side variables; do NOT put them in guest/home/user/.zshrc
    export CLODPOD_CLAUDE_ARGS="--remote-control"
    clod claude

The variables are forwarded over SSH and appended to the agent's exec invocation after its
mandatory flags (e.g. `--dangerously-skip-permissions`) and before any arguments you pass on the
command line. Word-splitting applies, so multiple flags work fine:

    CLODPOD_CLAUDE_ARGS="--remote-control --debug" clod claude

---

TL;DR:

The `user` folder is where you can store files that will be copied into the clodpod home directory. It is included in `.gitignore` so they won't be considered part of this repository.

Any zsh configuration files in `user` will be sourced as they are normally:

    .zshenv → .zprofile → .zshrc → .zlogin → .zlogout

All files will be copied to the `$HOME` directory during setup.

Run `clod --rebuild-dst` to rebuild after making changes in the user directory (only needs to be done once).


## Build process

To speed up building virtual machines, this project creates a base image (`clodpod-xcode-base`) that contains common software packages, then creates the destination image (`clodpod-xcode`), which includes configuration files.

If you add or modify config files in the `user` directory, rebuild the destination image with `clod --rebuild-dst`. Because this builds from the base image it's a fast operation.

If there are extensive changes to (brew) software packages, you can rebuild the base image with `clod --rebuild-base` to speed up future rebuilds.
