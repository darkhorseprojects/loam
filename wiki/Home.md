# loam wiki

loam is a fullscreen terminal-cell painter. Zig owns the terminal, canvas, selection, particles, and event loop. Lua brushes own behavior, glyphs, number keys, previews, and animation policy.

## pages

- [installation](./installation.md)
- [brush API](./brush-api.md)
- [system model](./system.md)
- [input and security boundary](./system.md#input-and-security-boundary)

## quick start

```sh
zig build
./zig-out/bin/loam --list
```

or install a release:

```sh
curl -fsSL https://raw.githubusercontent.com/darkhorseprojects/loam/v0.1.0/scripts/install.sh | sh
```

## core idea

the engine is boring on purpose. it does not know what a box, line, seed, moss, floral, or particle brush is. each shipped brush is just a Lua file:

```text
brushes/
  box.lua
  line.lua
  eraser.lua
  seed.lua
  soil.lua
  moss.lua
  floral.lua
  particles.lua
```

Lua decides what happens on mouse press, mouse move, mouse release, digits, paste, resize, and frame events.
