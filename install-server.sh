#!/usr/bin/env bash
# install-server.sh
# Installs the zellij binary to /usr/local/bin on a remote Linux host.
# Run ONCE per new host, by hand. This is the ONLY thing that touches a server.
# It installs nothing on login and adds no shell hooks.
#
#   curl -fsSL https://raw.githubusercontent.com/talmo/zellij-vscode/main/install-server.sh | bash
#
# To pin a version, replace `latest/download` below with `download/vX.Y.Z`.
set -euo pipefail

case "$(uname -m)" in
  aarch64|arm64) target=aarch64 ;;
  *)             target=x86_64 ;;
esac

url="https://github.com/zellij-org/zellij/releases/latest/download/zellij-${target}-unknown-linux-musl.tar.gz"
tmp="$(mktemp -d)"
echo "Downloading $url"
curl -fL "$url" | tar xz -C "$tmp"
sudo install "$tmp/zellij" /usr/local/bin/
rm -rf "$tmp"
echo "OK  $(command -v zellij) -> $(zellij --version)"
