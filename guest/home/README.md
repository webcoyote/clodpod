

TL;DR:

The `user` folder is where you can store files that will be copied into the VM home directory. It is included in `.gitignore` so they won't be considered part of this repository.

Any zsh configuration files in `user` will be sourced as they are normally:

    .zshenv → .zprofile → .zshrc → .zlogin → .zlogout

All files will be copied to the `$HOME` directory during setup.

Run `clod --rebuild-dst` to rebuild after making changes in the user directory (only needs to be done once).


## Build process

To speed up building virtual machines, this project creates a base image that contains common software packages, then creates the destination image which includes configuration files.

If you add or modify config files in the `user` directory, rebuild the destination image with `clod --rebuild-dst`. Because this builds from the base image it's a fast operation.

If there are extensive changes to (brew) software packages, you can rebuild the base image with `clod --rebuild-base` to speed up future rebuilds.


## Per-project Homebrew dependencies (Brewfile)

Each mounted project can declare its own Homebrew dependencies in a [Brewfile](https://docs.brew.sh/Brew-Bundle-and-Brewfile) at the project root. Example:

    # ./Brewfile
    brew "jq"
    brew "rg"
    cask "graphviz"

ClodPod reconciles project Brewfiles at two moments:

1. **Instance creation** (`clod create`) — every project mounted into the new instance has its Brewfile applied as part of `configure.sh`.
2. **Shell entry** (`clod claude`, `clod shell`, `clod codex`, etc.) — `.zshrc` runs `brew bundle check` on the active project's Brewfile. If everything is satisfied, nothing happens; if drift is detected, `brew bundle install --no-upgrade` runs to reconcile.

This means:

- Projects added to a running instance via `clod set --dir name:path` pick up their Brewfile on the next shell entry — no rebuild required.
- Editing a project's Brewfile takes effect the next time you open a shell into that project.
- Steady-state cost is one `brew bundle check` per shell — fast.

### Path resolution

The default file is `./Brewfile` (at the project root). To override per session, set Homebrew's standard env var:

    HOMEBREW_BUNDLE_FILE=/path/to/Custom.brewfile clod claude my-project

The override only applies to single-project flows; instance-creation iterates each mounted project's own `./Brewfile`.

### Failure mode

A failing `brew bundle install` emits a loud `WARNING:` on stderr but never aborts the shell or instance creation. A broken Brewfile must not prevent you from getting into the VM to fix it.

### What ClodPod does *not* do

- No `brew bundle cleanup` — packages you installed manually inside the VM stay put. Pruning is your call.
- No `--upgrade` — pinned versions stay pinned. Run `brew upgrade` yourself when you want it.
- No `brew update` per-shell — that's part of base image build.
