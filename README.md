# ClodPod - MacOS VM for Claude Code

`scripts/clod` is a utility that creates a MacOS virtual machine specifically configured to run Claude Code with `--dangerously-skip-permissions`.


## Key Features
- Manages MacOS virtual machine configured for Claude Code
- Supports multiple active projects in VM
- Optional `--no-graphics` mode for headless operation

## Usage

```bash
# Clone the project to a well-known location
git clone https://github.com/webcoyote/clodpod ~/projects/clodpod

# Change to your project directory, which will be mapped into the virtual machine
cd "YOUR PROJECT DIRECTORY"

# Build and run virtual machine with your project activated in Claude Code
~/projects/clodpod/scripts/clod run

# Stop all virtual machines related to this project
~/projects/clodpod/scripts/clod stop

# Add/remove/list additional projects from the virtual machine
~/projects/clodpod/scripts/clod add "PROJECT DIRECTORY"
~/projects/clodpod/scripts/clod remove "PROJECT DIRECTORY"
~/projects/clodpod/scripts/clod list

# Build and run virtual machine but start with a shell prompt instead of claude
~/projects/clodpod/scripts/clod run
```

## License

This project is licensed under the Apache License, Version 2.0. See [LICENSE.md](LICENSE.md) for details. ClodPod Copyright (C) Patrick Wyatt 2025. All rights reserved.

## Contributors

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for the list of contributors to this project.
