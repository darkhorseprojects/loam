# system model

loam is split into engine primitives and brush-owned behavior.

## engine modules

```text
src/main.zig
  app loop, args, input routing, clipboard, selection move

src/terminal.zig
  raw terminal, ANSI escape output, mouse reporting, paste, resize

src/canvas.zig
  persistent world, viewport, stage, particles, renderer

src/lua_bridge.zig
  Lua VM, ctx API, event tables, brush loading

src/brushes.zig
  brush discovery and active brush index

src/mcp.zig
  optional stdio MCP helper server, also reachable through `loam --mcp`
```

## canvas model

the canvas is not just the visible terminal grid. it has:

- a persistent world
- a viewport into that world
- a temporary stage layer
- a particle array

resize and font zoom change the viewport, not the world. existing marks are preserved.

## mouse model

mouse input is event-based:

- left press/move/release go to the active Lua brush
- right drag creates a selection rectangle
- right release copies and keeps the selection
- left drag inside the selection moves cells
- left click deselects the selection, but left drag still moves it

holding the mouse still does not repeatedly call the brush. brushes opt into continuous behavior with `animated = true` and `frame` events.

## memory model

loam reuses long-lived buffers and keeps per-frame allocation small:

- canvas cells and particles live in Zig arrays
- the stage is a fixed-size layer
- preview text is reused through an ArrayList capacity
- Lua brush file contents are freed after load
- MCP messages are parsed with a freeing allocator and deinitialized

## input and security boundary

- Zig owns terminal IO, canvas memory, particles, selection, clipboard, and routing.
- Lua owns brush-local state, glyph choices, placement decisions, preview content, number-key behavior, and animation policy.
- a brush receives plain event tables and a small `ctx` API. it does not get Zig pointers, filesystem handles, network access, or process spawning from loam.
- Lua brushes are trusted local code. the embedded Lua VM is initialized with standard Lua libraries, so a malicious brush can still do Lua-side damage inside the process.
- a future sandbox mode can tighten this further by opening only the functions loam explicitly exposes.

## platform model

the terminal backend is POSIX-oriented:

- Linux
- macOS
- BSD targets with `TIOCGWINSZ`

Windows is not supported yet because raw terminal IO, mouse reporting, alternate screen, and clipboard behavior need a separate console backend.
