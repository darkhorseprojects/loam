#!/usr/bin/env sh
set -eu

if [ -n "${LOAM_VERSION:-}" ]; then
  VERSION="$LOAM_VERSION"
else
  if command -v curl >/dev/null 2>&1; then
    VERSION=$(curl -fsSL https://api.github.com/repos/darkhorseprojects/loam/releases/latest | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p')
  elif command -v wget >/dev/null 2>&1; then
    VERSION=$(wget -qO- https://api.github.com/repos/darkhorseprojects/loam/releases/latest | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p')
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
fi

if [ -z "$VERSION" ]; then
  echo "could not determine latest loam version; set LOAM_VERSION=v1.2.3" >&2
  exit 1
fi
VERSION=${VERSION#v}

INSTALL_DIR="${LOAM_INSTALL_DIR:-$HOME/.local/bin}"
if [ -n "${XDG_DATA_HOME:-}" ]; then
  DATA_DIR="$XDG_DATA_HOME/loam"
else
  DATA_DIR="$HOME/.local/share/loam"
fi
TMP_DIR="${TMPDIR:-/tmp}/loam-install.$$"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

case "$(uname -s)" in
  Linux) os="linux" ;;
  Darwin) os="macos" ;;
  FreeBSD|OpenBSD|NetBSD|DragonFly)
    echo "BSD release assets are not published; build from source" >&2
    exit 1
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x86_64" ;;
  aarch64|arm64) arch="aarch64" ;;
  *)
    echo "unsupported arch: $(uname -m)" >&2
    exit 1
    ;;
esac

asset="loam-${VERSION}-${os}-${arch}.tar.gz"
url="https://github.com/darkhorseprojects/loam/releases/download/v${VERSION}/${asset}"

mkdir -p "$TMP_DIR" "$INSTALL_DIR" "$DATA_DIR"

if command -v curl >/dev/null 2>&1; then
  curl -fL "$url" -o "$TMP_DIR/$asset"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$TMP_DIR/$asset" "$url"
else
  echo "curl or wget is required" >&2
  exit 1
fi

tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR"
install -m 0755 "$TMP_DIR/loam" "$INSTALL_DIR/loam"
if [ -f "$TMP_DIR/loam-mcp" ]; then
  install -m 0755 "$TMP_DIR/loam-mcp" "$INSTALL_DIR/loam-mcp"
fi

if [ -d "$TMP_DIR/brushes" ]; then
  rm -rf "$DATA_DIR/brushes"
  cp -R "$TMP_DIR/brushes" "$DATA_DIR/brushes"
fi

echo "installed loam $VERSION to $INSTALL_DIR/loam"
if [ -f "$INSTALL_DIR/loam-mcp" ]; then
  echo "installed loam-mcp $VERSION to $INSTALL_DIR/loam-mcp"
fi
echo "installed bundled brushes to $DATA_DIR/brushes"
