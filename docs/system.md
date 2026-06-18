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

the terminal backend is POSIX-oriented:

- Linux
- macOS
- BSD targets with `TIOCGWINSZ`

Windows is not supported yet because raw terminal IO, mouse reporting, alternate screen, and clipboard behavior need a separate console backend.
