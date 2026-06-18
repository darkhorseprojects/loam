# installation

## release install

```sh
curl -fsSL https://raw.githubusercontent.com/darkhorseprojects/loam/v0.1.0/scripts/install.sh | sh
```

optional install location:

```sh
curl -fsSL https://raw.githubusercontent.com/darkhorseprojects/loam/v0.1.0/scripts/install.sh | LOAM_INSTALL_DIR="$HOME/.local/bin" sh
```

the script downloads the matching GitHub release asset for:

- Linux x86_64
- Linux aarch64
- macOS x86_64
- macOS aarch64

## source install

requires Zig 0.16.0.

```sh
zig build
./zig-out/bin/loam --list
```

debug builds:

```sh
zig build -Doptimize=Debug
```

## user brushes

```sh
mkdir -p ~/.config/loam/brushes
cp my-brush.lua ~/.config/loam/brushes/
```

then run:

```sh
loam --brush=my-brush
```

## version bumps

the version lives in `src/version.zig`.

```sh
scripts/bump-version.sh 0.2.0
```

release tags should use `v0.2.0`.
