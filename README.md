# Devcontainer template

A firewalled devcontainer for Claude Code. It merges the setups of krypto and
pontoon. The container starts as root, applies an outbound allow-list, and then
runs the workload as `node`.

## Use it in a new project

1. Put `.devcontainer/` and the three `devcontainer-*.sh` scripts in the repository root.
2. Set `COMPOSE_PROJECT_NAME` in `.devcontainer/.env`.
3. Add the hosts of the project to `.devcontainer/allowed-domains.conf`.
4. If the dev server listens on a port other than 4000 or 8000, change the inbound rules in `init-firewall.sh`.
5. If the project needs a JDK other than 25, change `TEMURIN_VERSION` in the `Dockerfile`.
6. Run `./devcontainer-restart.sh` on the host.

## Scripts

All three scripts run on the host.

- `devcontainer-restart.sh` reads `GH_TOKEN` from 1Password, then rebuilds and
  starts the container. It needs the `op` CLI. Claude Code installs its plugin
  from GitHub with this token.
- `devcontainer-shell.sh` opens a shell as `node`.
- `devcontainer-firewall-restart.sh` applies the allow-list again without a
  rebuild.

## Playwright

The build context is the repository root, so the image can read
`package-lock.json`. If the lock file pins Playwright, the image installs the
Chromium build of that version. If not, it installs the newest one.
`Dockerfile.dockerignore` limits the build context to the files the image needs.
