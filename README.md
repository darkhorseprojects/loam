# loam

fullscreen terminal-cell painter. Zig engine, Lua brushes.

## install

Linux/macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/darkhorseprojects/loam/main/scripts/install.sh | sh
```

Windows PowerShell:

```powershell
iwr https://raw.githubusercontent.com/darkhorseprojects/loam/main/scripts/install.ps1 -UseB | iex
```

Release assets:

- Linux x86_64
- Linux aarch64
- macOS aarch64
- macOS x86_64
- Windows x86_64

From source:

```sh
zig build
./zig-out/bin/loam --list
./zig-out/bin/loam --brush=text
```

## controls

| input | action |
| --- | --- |
| scroll | switch brush |
| numbers | brush-local controls |
| `0` | reset bundled brush state |
| left drag | paint |
| right drag/release | select/copy rectangle |
| left drag inside selection | move selection |
| middle click / `v` | paste internal clipboard |
| `c` | clear canvas and particles |
| `r` | clear selection / cancel move |
| `esc` | cancel active gesture or text input |
| repeated `esc` | countdown, then clear canvas |
| `q` | quit |

## brushes

A brush is a `.lua` file with:

```lua
local brush = { name = "star", glyph = "*" }

function brush.paint(ctx, event)
  if event.type == "mouse" and event.button == "left" and event.action ~= "release" then
    ctx.set(event.world_x, event.world_y, brush.glyph)
  end
end

return brush
```

Bundled brushes:

```text
box eraser floral line moss particles seed soil text
```

Brush folders, first match wins by file stem:

```text
./brushes
$XDG_CONFIG_HOME/loam/brushes
~/.config/loam/brushes
%APPDATA%/loam/brushes
$XDG_DATA_HOME/loam/brushes
~/.local/share/loam/brushes
%LOCALAPPDATA%/loam/brushes
/usr/local/share/loam/brushes
/usr/share/loam/brushes
```

Linux release installs bundled brushes to:

```text
~/.local/share/loam/brushes
```

Put custom Linux brushes in:

```text
~/.config/loam/brushes
```

Windows installer uses:

```text
%APPDATA%\loam\brushes
```

## Lua ctx

```lua
ctx.set(x, y, glyph)
ctx.get(x, y)
ctx.line(x0, y0, x1, y1, glyph)
ctx.fill(x, y, width, height, glyph)
ctx.rect(x, y, width, height, edge, fill_or_nil)
ctx.stageSet(x, y, glyph)
ctx.stageClear()
ctx.commitStage()
ctx.clear()
ctx.requestText(label)
ctx.emit(x, y, glyph, ttl, vx, vy)
ctx.particleCount()
ctx.getParticle(i)
ctx.setParticle(i, x, y, vx, vy, glyph, ttl, age)
ctx.removeParticle(i)
ctx.eachParticle(fn)
ctx.time()
ctx.dt()
ctx.random()
ctx.randomRange(a, b)
```

Text input is engine-owned. A brush calls `ctx.requestText("text")`; loam records keys, shows a top-left status line, and sends `event.type == "text"` events to Lua. Lua never reads stdin.

## MCP

Run stdio MCP helper:

```sh
loam --mcp
loam-mcp
```

Single tool:

```text
loam_apply_selection
```

Arguments:

```json
{
  "input_file": "map.txt",
  "output_file": "map.out.txt",
  "mode": "fill",
  "placement_char": "#",
  "target_char": ".",
  "target": {"line": 1, "column": 1},
  "selection": {"line": 1, "column": 1, "width": 10, "height": 4},
  "points": [{"line": 1, "column": 1}, {"line": 4, "column": 10}]
}
```

Modes:

- `fill`: fill rectangle, replace target chars in rectangle, or replace connected `target_char` section.
- `path`: draw a continuous path through `points`; with `target_char`, only matching cells on the path are replaced.

If `target_char` finds multiple disconnected sections, specify `target.line` and `target.column`.

## platform notes

- terminal rendering is diffed; no full-screen clear per frame
- render never calls Lua
- canvas owns durable cells and particles
- renderer owns overlays, preview, selection, move preview, status lines
- Windows builds and releases exist; interactive Windows Terminal UX still needs manual testing
- BSD release assets are not published

current version: **0.1.11**
