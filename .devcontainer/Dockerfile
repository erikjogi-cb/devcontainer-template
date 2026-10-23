FROM node:24-trixie

ARG TZ
ENV TZ="$TZ"

# Configure locale
RUN apt-get update && apt-get install -y --no-install-recommends locales \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  postgresql-client \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Temurin JDK (tarball from Eclipse Adoptium GitHub releases). The
# release tag and the file names derive from TEMURIN_VERSION. Pick a release
# that has both the x64 and the aarch64 Linux build: Adoptium sometimes
# publishes x64 first (25.0.5+8 had no aarch64 build on 2026-10-22).
ARG TEMURIN_VERSION=25.0.4.1+1
RUN ARCH=$(dpkg --print-architecture) \
  && case "$ARCH" in amd64) JDK_ARCH=x64 ;; arm64) JDK_ARCH=aarch64 ;; *) echo "unsupported arch $ARCH" && exit 1 ;; esac \
  && MAJOR="${TEMURIN_VERSION%%.*}" \
  && TAG="jdk-$(echo "$TEMURIN_VERSION" | sed 's/+/%2B/')" \
  && FILE_VERSION="$(echo "$TEMURIN_VERSION" | tr + _)" \
  && wget -q "https://github.com/adoptium/temurin${MAJOR}-binaries/releases/download/${TAG}/OpenJDK${MAJOR}U-jdk_${JDK_ARCH}_linux_hotspot_${FILE_VERSION}.tar.gz" -O /tmp/jdk.tar.gz \
  && mkdir -p /opt/jdk \
  && tar -xzf /tmp/jdk.tar.gz -C /opt/jdk --strip-components=1 \
  && rm /tmp/jdk.tar.gz
ENV JAVA_HOME=/opt/jdk
ENV PATH=$JAVA_HOME/bin:$PATH

# Install system dependencies for Playwright Chromium
RUN npx -y playwright install-deps chromium

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.20.1
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.1
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
RUN cat >> ~/.zshrc <<'EOF'
claude() {
  command claude --dangerously-skip-permissions "$@"
}
EOF

# Download the Chromium build the project's own Playwright expects. Installing with
# `npx -y playwright` would take the newest release on npm instead, and a browser build that
# does not match package-lock.json fails every E2E run at browser launch — with no way to
# repair it later, because the CDN sits behind the firewall. A project without a
# package-lock.json that pins Playwright gets the newest release. The Dockerfile is copied
# only so that COPY has one source that always exists.
COPY --chown=node:node .devcontainer/Dockerfile package*.json /tmp/playwright/
RUN cd /tmp/playwright \
  && if [ -f package-lock.json ] && grep -q '"node_modules/playwright"' package-lock.json; then \
       npm ci --ignore-scripts && ./node_modules/.bin/playwright install chromium; \
     else \
       npx -y playwright install chromium; \
     fi \
  && rm -rf /tmp/playwright

# Add github.com keys to known_hosts
RUN mkdir -p -m 0700 ~/.ssh && ssh-keyscan -t ed25519,ecdsa,rsa github.com >> ~/.ssh/known_hosts

# Use gh as the git credential helper
RUN gh auth setup-git --hostname github.com --force
RUN git config --global url."https://github.com/".insteadOf "git@github.com:"

# Copy and set up firewall script + its allow-list config (kept side by side so
# init-firewall.sh finds allowed-domains.conf whether run from here or the mount)
COPY .devcontainer/init-firewall.sh /usr/local/bin/
COPY .devcontainer/allowed-domains.conf /usr/local/bin/
COPY .devcontainer/entrypoint.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

# The container starts as root so the entrypoint can apply the firewall, then
# drops to node via setpriv for the workload. node holds no sudo rights, so the
# firewall cannot be altered from inside — root is reachable only from the host
# (`docker exec -u 0`). Open an interactive node shell with devcontainer-shell.sh.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
