

- Download SDKS
    mkdir "$HOME/Downloads"
    xcodebuild -downloadPlatform ios


- Create a base image that's brew installed & updated to make setup faster

- Use --no-graphics

- Running clodpod from a different directory when the VM is still running uses the old directory

- How to handle running multiple projects and worktrees

- Setup a user on the local machine that accepts a limited set of commands, specifically: notifications, running the simulator.


mkdir -p "$HOME/projects"
fd -t d --maxdepth 1 . "/Volumes/My Shared Files" -0 \
    | xargs -0I {} ln -sf '{}' "$HOME/projects/$(basename '{}')"
