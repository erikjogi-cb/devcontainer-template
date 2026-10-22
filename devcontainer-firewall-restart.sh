#!/bin/sh
# Re-apply the firewall inside the running devcontainer, without a full restart.
# Runs the bind-mounted init-firewall.sh (your live edits under .devcontainer/)
# as root, since node holds no privileges inside the container. Use after
# editing the allow-list; for a throwaway single host, adding the IP to the
# `allowed-domains` ipset is less disruptive than a full re-apply.
#
# Runs from .devcontainer so compose resolves its docker-compose.yml and .env
# (COMPOSE_PROJECT_NAME) exactly as an in-directory invocation would.
set -e
cd "$(dirname "$0")/.devcontainer"
exec docker compose exec -u 0 app bash /workspace/.devcontainer/init-firewall.sh
