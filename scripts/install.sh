#!/usr/bin/env sh
set -eu

VERSION="${LOAM_VERSION:-0.1.0}"
INSTALL_DIR="${LOAM_INSTALL_DIR:-$HOME/.local/bin}"
TMP_DIR="${TMPDIR:-/tmp}/loam-install.$$"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

case "$(uname -s)" in
  Linux) os="linux" ;;
  Darwin)
    os="macos"
    case "$(uname -m)" in
      x86_64|amd64)
        echo "macOS x86_64 release assets are not built yet; build from source for now" >&2
        exit 1
        ;;
    esac
    ;;
  FreeBSD|OpenBSD|NetBSD|DragonFly) os="bsd" ;;
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

mkdir -p "$TMP_DIR" "$INSTALL_DIR"

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

echo "installed loam $VERSION to $INSTALL_DIR/loam"
