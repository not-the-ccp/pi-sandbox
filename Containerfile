# Podman-safe container for PI (https://pi.dev)
FROM archlinux:latest

RUN printf '%s\n' \
      'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
      > /etc/pacman.d/mirrorlist \
    && pacman -Syu --noconfirm --disable-download-timeout --needed \
      base-devel \
      git github-cli \
      python python-pip \
      nodejs npm \
      ripgrep fd fzf jq \
      neovim less openssh curl ca-certificates unzip tar \
      iproute2 iputils \
    && pacman -Scc --noconfirm \
    && npm install -g --ignore-scripts @earendil-works/pi-coding-agent \
    && npm cache clean --force \
    && useradd -m -s /bin/bash agent \
    && mkdir -p /workspace \
    && chown agent:agent /workspace /home/agent

USER agent
WORKDIR /workspace
ENV HOME=/home/agent TERM=xterm-256color LANG=C.UTF-8
CMD ["pi", "--help"]
