#!/bin/sh
# Open an interactive shell in the devcontainer as `node` (from the host).
#
# The container runs as root (so the entrypoint can apply the firewall) and
# drops the workload to node. A bare `docker exec` would therefore land you in
# root; `-u node` gives node's home, the ~/.claude + history volumes, and the
# container's environment (unlike `su - node`, which strips it).
#
# Runs from .devcontainer so compose resolves its docker-compose.yml and .env
# (COMPOSE_PROJECT_NAME) exactly as an in-directory invocation would.
set -e
cd "$(dirname "$0")/.devcontainer"
exec docker compose exec -u node app "${1:-zsh}"
