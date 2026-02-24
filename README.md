<div align="center" id="clodpod">
<a href="https://github.com/webcoyote/clodpod" title="clodpod">
  <img src="./assets/icon.jpg" alt="Clodpod Banner" width="128">
</a>
</div>

---

# ClodPod - Run AI agents in a macOS VM sandbox

ClodPod creates a macOS virtual machine sandbox configured to run applications like Claude Code, Open AI Codex, Google Gemini. It facilitates disabling AI permission prompts so you can get work done without risking your entire computer.

ClodPod maps any number of your project directories into the virtual machine so AI agents can work on your code while remaining isolated from your host computer.

ClodPod virtual machines include Xcode and common development tools, and it's easy to extend to add your own development tools and configuration files.

Key features:

- Builds a virtual machine and launches AI agents with access to your projects
- Enables mapping multiple projects in the same virtual machine simultaneously
- Open multiple AI agents sessions and shell prompts, or use the GUI
- Headless mode for CI/CD workflows with `--no-graphics`
- Includes Xcode and common development tools; you can add your own tools too
- Fast rebuild and relaunch using a two-layer caching system


Usage:

    # Clone clodpod
    git clone https://github.com/webcoyote/clodpod ~/projects/clodpod

    # Create an alias for clod or add it to your path
    alias clod="$HOME/projects/clodpod/clod"
    # - or -
    alias clod="$HOME/projects/clodpod/clod --no-graphics"
    # - or -
    PATH="$PATH:"$HOME/projects/clodpod"

    # Note: for the first run you'll want to start in the project directory,
    # which will get remembered. Use add/remove for changing projects.
    cd "YOUR PROJECT DIRECTORY"

    # Run Claude Code
    clod claude
    # also clod cl"

    # Run OpenAI Codex
    clod codex
    # also "clod co"

    # Run Google Gemini
    clod gemini
    # also "clod g"

    # Or a command shell
    clod shell
    # also "clod s"

    # Start virtual machine (useful for utilizing Virtual Machine GUI apps)
    clod start

    # Enable passwordless sudo for clodpod user
    clod --allow-sudo shell

    # Disable passwordless sudo for clodpod user (default)
    clod --no-allow-sudo shell

    # Set a custom login password for the clodpod account
    # NOTE: add a space to the beginning of the command
    # to prevent its inclusion in your shell history to
    # avoid leaking your passwords there :)
     CLODPOD_PASSWORD='your-password' clod shell

    # Stop all clodpod virtual machines
    clod stop

    # Add/remove/list projects
    clod add "THIRD PROJECT DIRECTORY"          # also "clod a ..."
    clod remove "FOURTH PROJECT DIRECTORY"      # also "clod rm ..."
    clod list                                   # also "clod l", "clod ls"


## macOS versions

By default ClodPod uses the `ghcr.io/cirruslabs/macos-tahoe-xcode:latest` VM flavor, but this is configurable by setting the MACOS_VERSION and MACOS_FLAVOR environment variables when building the VM:

    MACOS_VERSION=sequoia MACOS_FLAVOR=vanilla clod shell

See the [cirrus packages page on Github](https://github.com/orgs/cirruslabs/packages?tab=packages&q=macos-) to see the available alternatives.


## Setup notes

By default the guest CPU count is set to be identical to the host system, and guest memory to `5/8 * host memory` (NOTE1) to provide resources for compiling projects in Xcode.

NOTE1: This value was empirically calculated (N=1) to leave plenty of memory for web-browsing, which I shouldn't be doing anyway.

Optional virtual machine configuration (example):

    tart set clodpod-xcode --cpu 8
    tart set clodpod-xcode --memory "$(( $(sysctl -n hw.memsize) * 2 / 3 / 1024 / 1024 ))"


## Add your own tools and configuration

To add custom configuration; see `./guest/home/README.md`.


# Background

This project exists because I was foolishly trying to find a way to insulate my computer from destruction by rogue AI agents when running (e.g.) Claude Code with `--dangerously-skip-permissions` (to avoid frequent "do you want to proceed?" dialogs), when perhaps I should have simply learned to accept their infrequent rages.

I experimented with running AI agents inside docker and podman containers (i.e. in Linux), but as my goal ultimate is to build apps using Xcode, I wanted to stick with OSX.

I considered using xtool, but instead went down a different rabbit hole and tried providing the containers with limited access from the guest OS to my host computer using GNU Rush (Remote User SHell). This worked but was limiting.

I then tried limiting filesystem access using exec-sandbox, and it works in a "proof-of-concept" sort of way, but the attack surface area was too large. I expect I'll come back to this because sandboxing is quite interesting all by itself.

Eventually I settled on running the whole thing inside a virtual machine, which is probably where I should have started.

In any event, this project is the result. Hope you like it.


# Alternatives

- [SandVault](https://github.com/webcoyote/sandvault) runs AI agents in a limited user account on macOS.
- [Chamber](https://github.com/cirruslabs/chamber) is a proof-of-concept app for running Claude Code inside a macOS virtual machine.
- [Claude Code Sandbox](https://github.com/textcortex/claude-code-sandbox) runs Claude Code in a Docker container (Linux)

# License

Apache License, Version 2.0

ClodPod Copyright © 2025 Patrick Wyatt

See [LICENSE.md](LICENSE.md) for details.


# Contributors

We welcome contributions and bug reports.

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for the list of contributors to this project.


# Thanks to

This project builds on the great works of other open-source authors:

- [Tart](https://tart.run): macOS and Linux VMs on Apple Silicon
- [Homebrew](https://brew.sh): 🍺 The missing package manager for macOS (or Linux)
- [Sqlite](https://sqlite.org): The most used database engine in the world
- [Shellcheck](https://www.shellcheck.net): finds bugs in your shell scripts
- [uv](https://docs.astral.sh/uv/): An extremely fast Python package and project manager, written in Rust
- [Claude Code Hooks Mastery](https://github.com/disler/claude-code-hooks-mastery): Quickly master how to use Claude Code hooks to add deterministic (or non-deterministic) control over Claude Code's behavior
- [StatusLine](https://gist.github.com/dhkts1/55709b1925b94aec55083dd1da9d8f39): project status information for Claude Code

... as well as GNU, BSD, Linux, Git, Sqlite, Node, Python, netcat, jq, and more. "We stand upon the shoulders of giants."
