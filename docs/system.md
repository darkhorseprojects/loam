# system

## ownership

- canvas: durable cells and particles
- Lua bridge: active brush VM, ctx API, cached preview
- renderer: visible frame, overlays, selection, move preview, status lines, diffing
- terminal backend: raw input/output and size
- app loop: routing, brush switching, text capture, clipboard, escape semantics

Rendering never calls Lua.

## brush lookup

First matching file stem wins:

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

## text input

Lua calls `ctx.requestText(label)`. The engine captures keys, shows a top-left status line, and sends `text` events through `paint`. Lua does not read stdin.

Status lines stack top-left, so text input and escape clear countdown do not overlap.

## platform

Release assets:

```text
linux x86_64
linux aarch64
macos aarch64
macos x86_64
windows x86_64
```

FreeBSD x86_64 is compile-checked. BSD release assets are not published.

## MCP

`loam --mcp` and `loam-mcp` expose one tool: `loam_apply_selection`.

Modes:

- `fill`: rectangle fill, target-char fill in rectangle, or connected target-char section fill
- `path`: continuous path through points

MCP edits text files only. It does not control a live editor session.
