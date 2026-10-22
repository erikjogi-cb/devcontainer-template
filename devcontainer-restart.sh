#!/bin/sh
# Rebuild and restart the devcontainer from the host.
# Runs from .devcontainer so compose picks up its docker-compose.yml and .env
# (COMPOSE_PROJECT_NAME) exactly as an in-directory invocation would.
cd "$(dirname "$0")/.devcontainer"
export GH_TOKEN=`op read "op://Employee/claude-agents-github-token/password"`
docker compose down && docker compose build --progress=plain && docker compose up -d --remove-orphans
