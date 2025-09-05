# ClodPod - Run Claude Code safely in a macOS VM

ClodPod creates a macOS virtual machine configured to run Claude Code with `--dangerously-skip-permissions`, avoiding permission prompts without risking your entire computer.

ClodPod maps any number of your project directories into the virtual machine so Claude Code can work on your code while remaining isolated from your host computer.

ClodPod virtual machines include Xcode and common development tools, and it's easy to extend to add your own development tools and configuration files.

Key features:

- Builds a virtual machine and launches Claude Code with access to your projects
- Enables mapping multiple projects in the same virtual machine simultaneously
- Open multiple Claude Code sessions and shell prompts, or use the GUI
- Headless mode for CI/CD workflows with `--no-graphics`
- Includes Xcode and common development tools; you can add your own tools too
- Fast rebuild and relaunch using a two-layer caching system


Usage:

    # Clone clodpod
    git clone https://github.com/webcoyote/clodpod ~/projects/clodpod

    # Create an alias for clod or add it to your path
    alias clod="$HOME/projects/clodpod/clod"
    # - or -
    PATH="$PATH:"$HOME/projects/clodpod"

    # Run clod from any of your project directories
    cd "YOUR PROJECT DIRECTORY"
    clod run

    # Or run a command shell
    cd "ANOTHER PROJECT DIRECTORY"
    clod shell

    # Stop all clodpod virtual machines
    clod stop

    # Add/remove/list projects
    clod add "THIRD PROJECT DIRECTORY"
    clod remove "FOURTH PROJECT DIRECTORY"
    clod list


## Setup notes

By default the guest CPU count is set to be identical to the host system, and guest memory to `5/8 * host memory` (NOTE1) to provide resources for compiling projects in Xcode.

NOTE1: This value was empirically calculated (N=1) to leave plenty of memory for web-browsing, which I shouldn't be doing anyway.

Optional virtual machine configuration (example):

    tart set clodpod-xcode --cpu 8
    tart set clodpod-xcode --memory "$(( $(sysctl -n hw.memsize) * 2 / 3 / 1024 / 1024 ))"


## Add your own tools and configuration

TL;DR:

- Add your own install instructions to `./guest/install.sh`, then `clodbuild run --rebuild-base`.
- Add your own user configuration to `./guest.configure.sh`, then `clod run --rebuild-dst`.

Long form:

To speed up building virtual machines, this project creates a base image (`clodpod-xcode-base`) that contains common software packages, then creates the destination image (`clodpod-xcode`), which includes configuration files.

In the event you update your config files (say, by modifying `./guest/configure.sh` or `./guest/home/.zshrc`) you can rebuild the destination image using `clod --rebuild-dst run`. Because this builds from the base image it's a fast operation.

If you want to install your own development tools, update `./guest/install.sh` and rebuild the base image to update using `clod --rebuild-base run`, which automatically rebuilds the destination image also.

In practice you can utilize either `install.sh` or `configure.sh` for your setup; the intended workflow is for large/slow operations (like `xcodebuild -downloadPlatform ios`) to occur in during `install.sh`, and small/fast ones during `configure.sh` so that you can quickly experiment with configuration changes without having to re-install all of your tools.


# Background

This project exists because I was foolishly trying to find a way to insulate my computer from destruction by rogue AI agents when running Claude Code with `--dangerously-skip-permissions` (to avoid frequent "do you want to proceed?" dialogs), when perhaps I should have simply learned to accept their infrequent rages.

I experimented with running Claude Code inside docker and podman containers (i.e. in Linux), but as my goal ultimate is to build apps using Xcode, I wanted to stick with OSX.

I considered using xtool, but instead went down a different rabbit hole and tried providing the containers with limited access from the guest OS to my host computer using GNU Rush (Remote User SHell). This worked but was limiting.

I then tried limiting Claude Code's filesystem access using exec-sandbox, and it works in a "proof-of-concept" sort of way, but the attack surface area was too large. I expect I'll come back to this because sandboxing is quite interesting all by itself.

Eventually I settled on running the whole thing inside a virtual machine, which is probably where I should have started.

In any event, this project is the result. Hope you like it.


# Alternatives

### Chamber

[Chamber](https://github.com/cirruslabs/chamber) is a proof-of-concept app for running Claude Code inside a macOS virtual machine.


# License

This project is licensed under the Apache License, Version 2.0. See [LICENSE.md](LICENSE.md) for details. ClodPod Copyright (C) Patrick Wyatt 2025. All rights reserved.


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
