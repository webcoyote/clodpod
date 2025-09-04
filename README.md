# ClodPod - MacOS VM for Claude Code

`clod` is a utility that creates a MacOS virtual machine specifically configured to run Claude Code with `--dangerously-skip-permissions`.


# Key Features

- Manages MacOS virtual machine configured for Claude Code
- Supports multiple active projects in VM
- Optional `--no-graphics` mode for headless operation


# Usage

```bash
# Clone the project to a well-known location
git clone https://github.com/webcoyote/clodpod ~/projects/clodpod

# Change to your project directory, which will
# get mapped into the virtual machine
cd "YOUR PROJECT DIRECTORY"

# Build & run virtual machine with your project inside Claude Code
~/projects/clodpod/scripts/clod run

# Stop all virtual machines related to this project
~/projects/clodpod/scripts/clod stop

# Add/remove/list additional projects from the virtual machine
~/projects/clodpod/scripts/clod add "PROJECT DIRECTORY"
~/projects/clodpod/scripts/clod remove "PROJECT DIRECTORY"
~/projects/clodpod/scripts/clod list

# Build & run virtual machine with shell instead of claude
~/projects/clodpod/scripts/clod run
```

## Resource notes

By default the guest CPU count is set to be identical to the host system, and guest memory to `5/8 * host memory` (NOTE1) to provide resources for compiling projects in Xcode.

NOTE1: This value was empirically calculated (N=1) to leave plenty of memory for web-browsing, which I shouldn't be doing anyway.


## Build Notes

To speed up building virtual machines, this project creates a base image (`clodpod-xcode-base`), which contains common software packages. It then creates the destination image (`clodpod-xcode`), which includes your configuration files.

In the event you update your config files (say, adding settings to `.zshrc`) you can rebuild the destination image using `clod --rebuild-dst run`. Because this builds from the base image it's a fast operation.

You can rebuild the base image to update using `clod --rebuild-base run`. This automatically rebuilds the destination image also. This is typically only necessary if you're working on developing clod itself.


# Background

This project exists because I was foolishly trying to find a way to insulate my computer from destruction by rogue AI agents when running Claude Code with `--dangerously-skip-permissions` (to avoid frequent "do you want to proceed?" dialogs), when perhaps I should simply learn to accept their infrequent rages.

I experimented with running Claude Code inside docker and podman containers (i.e. in Linux), but as my goal ultimate is to build apps using Xcode, I wanted to stick with OSX.

I considered using xtool, but instead went down a different rabbit hole and tried providing the containers with limited access from the guest OS to my host computer using GNU Rush (Remote User SHell). This sorta/kinda worked.

I then tried limiting Claude Code using exec-sandbox, and it works in a "proof-of-concept" sort of way, but the attack surface area is still huge. I expect I'll come back to this because sandboxing is quite interesting all by itself.

Eventually I settled on boxing the whole thing up inside a virtual machine, which is probably where I should have started.

In any event, this project is the result. Hope you like it.


# Alternatives

### Chamber

[Chamber](https://github.com/cirruslabs/chamber) runs Claude Code inside a macOS virtual machine.


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
