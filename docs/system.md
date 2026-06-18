# system

`loam` is split into engine primitives and brush-owned behavior.

## terminal.zig

native ANSI/SGR terminal handling:

- alternate screen
- hidden cursor
- raw mode
- POSIX `TIOCGWINSZ` terminal sizing
- SGR mouse reporting `?1002h`, `?1003h`, and `?1006h`
- mouse wheel as brush-cycle input
- paste detection
- bracketed paste `?2004h`
- resize events
- monotonic time and sleep

no TUI framework is used.

## canvas.zig

owns durable canvas data:

- terminal-cell grid
- UTF-8 cell storage
- persistent world plus viewport
- Lua brush stage preview layer
- particle array

the canvas does not know about brushes, selection, moves, or terminal output. it only stores cells and particles.

## lua_bridge.zig

owns the Lua VM and boundary:

- creates one `ctx` table per paint call
- pushes lightweight event tables
- exposes per-cell drawing, bulk drawing, particles, time, random, and size
- loads the selected brush file
- calls `brush.paint(ctx, event)`
- calls `brush.preview(ctx, width, height)` for the corner panel

Lua never reaches into Zig memory directly. Zig never encodes brush behavior.

## renderer.zig

owns the visible terminal frame:

- builds base cells from canvas and brush stage
- applies particles
- applies moving-selection overlay without mutating the world
- applies preview/countdown UI
- applies selection reverse-video last
- diffs the next frame against the previous frame
- writes only changed terminal cells

terminal output remains single-writer. compute can become worker-backed later, but renderer state is still one owner.

## main.zig

owns the app loop:

- parse args
- initialize terminal
- initialize canvas and Lua VM
- load all brushes from `brushes/`
- route input
- scroll wheel cycles the active brush and reloads Lua
- maintain internal clipboard
- run frame events only when needed
- ask the renderer to diff and patch visible cells after input/frame ticks
- handle escape cancel and repeated-escape clear countdown

## brush set

`brushes.zig` owns folder discovery:

- list `.lua` files in `brushes/`
- sort names
- read `brush.name` and `brush.glyph` for preview metadata
- keep an active index
- support folder-relative initial brush selection with `--brush=name`

all brush code still comes from the folder. the host only switches which file is loaded.

## copy/paste

right drag selects a rectangle. right release copies the selected cells as text into:

1. the internal loam clipboard
2. OSC 52 system clipboard when the terminal accepts it

middle click or `v` pastes the internal clipboard as a Lua `paste` event.

left drag inside a right-click selection moves those cells through a visual overlay. the world is not changed until release commits the move.

## color

there is no color model. selection highlight is reverse video only. brush scripts may write any glyph string supported by the terminal font.

## memory model

loam uses a long-lived arena for app-owned data and keeps per-frame allocations small:

- canvas cells, particles, brush lists, and preview buffer capacity are reused
- Lua brush file contents are freed after load
- MCP messages use a freeing allocator and deinitialize parsed JSON
- particles are stored in a Zig array; Lua receives numeric indices instead of allocating per-particle Lua tables
- staged previews are a fixed-size canvas layer, not a Lua table of cells
- moved selections are rendered as an overlay, not written into the canvas stage

## input and security boundary

- Zig owns terminal IO, canvas memory, particles, selection, clipboard, and routing.
- Lua owns brush-local state, glyph choices, placement decisions, preview content, number-key behavior, and animation policy.
- a brush receives plain event tables and a small `ctx` API. it does not get Zig pointers, filesystem handles, network access, or process spawning from loam.
- Lua brushes are still trusted local code. the embedded Lua VM is initialized with standard Lua libraries, so a malicious brush can still do Lua-side damage inside the process.
- a future sandbox mode can tighten this further by opening only the functions loam explicitly exposes.

## platform model

terminal IO is split by backend:

- `terminal_posix.zig` handles Linux, macOS, and BSD-style `TIOCGWINSZ` targets
- `terminal_windows.zig` handles Windows console mode setup, VT output, VT input, and console sizing
- `terminal_ansi.zig` owns shared ANSI mode strings and SGR mouse parsing
- `terminal_types.zig` owns shared events, keys, mouse events, paste events, and sizes

release assets are currently built for:

- Linux x86_64
- Linux aarch64
- macOS aarch64
- macOS x86_64
- Windows x86_64

FreeBSD x86_64 is source-build checked, but no BSD release asset is published until runtime behavior is tested in a BSD terminal. Windows x86_64 is build/release checked; interactive mouse/terminal UX still needs manual validation in Windows Terminal before calling it polished.

## renderer / Lua boundary update

rendering never calls Lua. `lua_bridge.zig` rebuilds the preview cache after brush load or brush events. `renderer.zig` consumes cached cells only.

`canvas.zig` now owns durable cells and particles only. brush drag previews use a renderer-owned overlay; moving selections use a separate move overlay. neither is written into the durable canvas until an explicit commit/release.

## brush inventory

`lua_bridge.zig` keeps `__loam_inventory[path] = brush_table` in the Lua VM. Brush switching reuses the cached table instead of reloading the file, so brush state survives until process exit.
