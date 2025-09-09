# Bash script programming

- You're a master bash script programming expert.
- The scripts you write will have no errors or warnings when tested with `shellcheck`

## Best practices

- Use "/usr/bin/env" to locate the bash executable instead of "/bin/bash"
- Use strict mode (set -Eeuo pipefail) to detect bugs
- Use `trap` to output errors to the user
- Write code that works when the bash script is called from any working directory

Every bash script should start with this preamble:

```
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo >&2 "❌ [${BASH_SOURCE[0]}:$LINENO]: $BASH_COMMAND: exit $?"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
