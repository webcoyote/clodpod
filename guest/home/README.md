

TL;DR:

The `user` folder is where you can store files that will be copied into the clodpod home directory. It is included in `.gitignore` so they won't be considered part of this repository.

Any zsh configuration files in `user` will be sourced as they are normally:

    .zshenv → .zprofile → .zshrc → .zlogin → .zlogout

All files will be copied to the `$HOME` directory during setup.

Run `clod --rebuild-dst run` to rebuild after making changes in the user directory (only needs to be done once).


## Build process

To speed up building virtual machines, this project creates a base image (`clodpod-xcode-base`) that contains common software packages, then creates the destination image (`clodpod-xcode`), which includes configuration files.

If you add or modify config files in the `user` directory, rebuild the destination image with `clod --rebuild-dst run`. Because this builds from the base image it's a fast operation.
