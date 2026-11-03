# How Ghostty works, with evidence

Two sources of evidence were collected on 2026-11-03:

1. **Source code.** A shallow clone of `github.com/ghostty-org/ghostty` at commit
   `18e645ea22a5ef4793a2008275eb6f98e5d039bb` (2026-11-02). Paths below are relative to the repo root.
2. **The installed binary.** `/Applications/Ghostty.app` version **1.4.0**, inspected with `file`,
   `otool -L`, and `nm`.

---

## 1. The big picture

Ghostty is a **cross-platform terminal core written in Zig**. Thin **native GUI shells** sit on top of it:
Swift/AppKit on macOS and GTK4 on Linux. Rendering is GPU-accelerated through **Metal** on macOS and
**OpenGL** on Linux.

```
                ┌──────────────── native app runtime ("apprt") ────────────────┐
                │ macOS: Swift/AppKit/SwiftUI (macos/)    Linux: GTK4 (src/apprt/gtk) │
                └──────────────┬───────────────────────────────────────────────┘
                               │ C ABI: include/ghostty.h  (ghostty_app_new, ghostty_surface_new, ghostty_surface_key …)
┌──────────────────────────────▼──────────────────────────────────────────────────────┐
│ Surface (src/Surface.zig) — one terminal pane; owns 3 threads:                         │
│                                                                                        │
│  main/UI thread ──keys/mouse──► input encoders (src/input/key_encode.zig) ──► writer   │
│                                                                                        │
│  IO reader thread:  pty read() ─► termio.processOutput ─► stream (SIMD UTF-8 decode)   │
│                     ─► Parser.zig (vt100.net state machine) ─► Terminal.zig/Screen.zig │
│                        (PageList of contiguous memory pages = screen + scrollback)    │
│  IO writer thread (src/termio/Thread.zig): writes to pty, mode changes                │
│                                                                                        │
│  Renderer thread (src/renderer/Thread.zig, libxev loop, CVDisplayLink on macOS):       │
│     lock state → build cell buffers → font grid/atlas (CoreText|FreeType+HarfBuzz)     │
│     → Metal (shaders.metal) | OpenGL (glsl/*) draw calls                               │
└────────────────────────────────────────────────────────────────────────────────────────┘
                               │ src/pty.zig / src/pty.c : openpty, setsid, TIOCSCTTY, TIOCSWINSZ
                               ▼
                         child shell (zsh/bash/fish…) + shell-integration scripts
```

---

## 2. Evidence, layer by layer

### 2.1 Language split: Zig core, Swift/GTK shells
| Fact | Evidence |
|---|---|
| The core is Zig | `find src -name '*.zig'` → **605** files; `build.zig` at the repo root |
| The macOS app is Swift | `find macos -name '*.swift'` → **197** files |
| The Linux app is GTK | `src/apprt/gtk/` → **57** Zig files |
| The installed app is a native universal binary | `file Ghostty.app/Contents/MacOS/ghostty` → `Mach-O universal binary … [x86_64] [arm64]` |

### 2.2 App runtime abstraction ("apprt")
`src/apprt.zig:17-20` selects a runtime at build time:
```zig
pub const gtk = @import("apprt/gtk.zig");
pub const none = @import("apprt/none.zig");
pub const embedded = @import("apprt/embedded.zig");
```
On macOS Ghostty uses the **embedded** runtime. The Zig core is compiled into a library that exposes a C API,
and Swift drives it:
- `include/ghostty.h:1155` `ghostty_init`, `:1178` `ghostty_app_new`, `:1194` `ghostty_surface_new`,
  `:1216` `ghostty_surface_key`.
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` calls `ghostty_surface_new`.
- **The binary confirms it.** `nm -gU Ghostty.app/Contents/MacOS/ghostty | grep -c ghostty_` → **90** exported
  C symbols, including `_ghostty_init`, `_ghostty_app_new`, `_ghostty_surface_new`, and `_ghostty_surface_key`.

### 2.3 PTY and process spawning
`src/pty.zig`:
- `:140` `c.openpty(...)` creates the master/slave pseudo-terminal pair.
- `:222` `ioctl(master, TIOCSWINSZ, …)` reports window size to the child (this is what triggers SIGWINCH).
- `:252` `setsid()` gives the child a new session; `:255` `ioctl(slave, TIOCSCTTY)` makes the pty its controlling tty.

`src/termio/Exec.zig` manages the child: its environment, shell integration, and killing its process group.

### 2.4 Threads: IO reader, IO writer, renderer
- `src/Surface.zig:99` `renderer_thread`, `:135` `io_thread`, `:754` `std.Thread.spawn(...)`.
- `src/termio/Thread.zig:1-9`: *"the 'writer' thread for terminal IO. The reader side is handled by the
  Termio struct … The goal is to offload as much from the reader thread as possible since it is the hot path
  in parsing VT sequences and updating terminal state."*
- `src/renderer/Thread.zig:1-2`: *"the renderer thread logic … able to be woken up to render"*. It runs
  a **libxev** event loop (`:35 loop: xev.Loop`, `:39 wakeup: xev.Async`).
- `src/renderer/DisplayLink.zig:1`: on macOS, frames are paced by a **CVDisplayLink**.

### 2.5 The hot path: bytes → parser → terminal state
- `src/termio/Termio.zig:705` `processOutput(buf)` → `:750/753` `terminal_stream.next(byte)` / `nextSlice(buf)`.
- `src/terminal/stream.zig:880` `simd.vt.utf8DecodeUntilControlSeq(...)` uses SIMD to decode runs of
  plain UTF-8 text until it reaches the next escape sequence. This is a large part of Ghostty's throughput.
- `src/terminal/Parser.zig:1-4`: *"VT-series parser … implemented directly as the state machine described on
  vt100.net"*. States at `:15-29`: `ground, escape, escape_intermediate, csi_entry, csi_param, csi_ignore,
  dcs_*, osc_string, sos_pm_apc_string`.
- `src/terminal/Terminal.zig` holds the semantic operations: `:1833 print`, `:2456 carriageReturn`,
  `:2470 linefeed`, `:3175 setCursorPos`, `:3340 scrollUp`, `:4381 eraseDisplay`, `:4658 setAttribute` (SGR).

### 2.6 Memory model: pages
- `src/terminal/PageList.zig:1`: *"Maintains a linked list of pages to make up a terminal screen"*.
- `src/terminal/page.zig:157`: *"Pages are always backed by a single contiguous block of memory"*. Cells,
  styles, graphemes, and hyperlinks are stored as offsets inside one allocation. That gives cache locality,
  cheap scrollback, and fast cloning for the renderer.

### 2.7 Rendering: GPU, font atlas, sprites
- `src/renderer.zig:18-19, 40-41` selects the backend: `.metal => Metal`, `.opengl => OpenGL`.
- `src/renderer/shaders/shaders.metal:191` `vertex … full_screen_vertex`, `:224` `fragment … bg_color_fragment`,
  plus `glsl/cell_text.v.glsl` and others for OpenGL. Cells are instanced quads sampled from a glyph atlas.
- **The binary confirms it.** `otool -L` shows links to `Metal.framework`, `MetalKit.framework`,
  `QuartzCore.framework`, and `CoreText.framework`.
- Fonts: `src/font/Atlas.zig` (texture atlas) and `src/font/shaper/{coretext,harfbuzz}.zig` (text shaping for
  ligatures and complex scripts). `src/font/sprite/` draws box-drawing, block, Powerline, and similar glyphs
  procedurally so adjacent cells join seamlessly.
- `src/renderer/shadertoy.zig` lets users apply custom GLSL post-processing shaders.

### 2.8 Input and protocol extensions
- `src/input/key_encode.zig:100` `fn kitty(...)` implements the **Kitty keyboard protocol**, alongside legacy xterm encoding.
- `src/terminal/kitty/graphics_*.zig` implements the **Kitty graphics protocol** (inline images).
- `src/terminal/osc/`, `hyperlink.zig` (OSC 8), `clipboard.zig` (OSC 52), `search/`, `tmux/` (tmux control mode).

### 2.9 Shell integration, config, themes
- `src/shell-integration/{bash,zsh,fish,elvish,nushell}` scripts are injected into the shell. They report the
  working directory and prompt marks, enable `jump_to_prompt`, and make new tabs open in the same directory.
- `src/config/Config.zig` defines the `key = value` config schema (about 200 top-level keys by a rough grep).
- The installed app ships `Contents/Resources/ghostty/themes` (**819** themes), `terminfo/`, `shell-integration/`,
  `man/`, and completions for bash, zsh, and fish.

---

## 3. How Mantis maps onto Ghostty

| Ghostty | Mantis (this repo) |
|---|---|
| `src/pty.zig` + `src/pty.c` | `Sources/CPTY/cpty.c` (`forkpty` = openpty+setsid+TIOCSCTTY, `TIOCSWINSZ`) |
| `src/terminal/Parser.zig` (vt100.net) | `Sources/MantisCore/Parser.swift` (same state machine) |
| `stream.zig` SIMD text fast path | `Parser.feed` ASCII-run fast path → `Terminal.printASCII` |
| `Terminal.zig` / `Screen.zig` | `Sources/MantisCore/Terminal.swift` |
| `PageList.zig` pages | `RingBuffer<Row>` scrollback (`Types.swift`) |
| `input/key_encode.zig`, `surface_mouse.zig` | `Sources/MantisCore/Input.swift` |
| `termio/Exec.zig` reader + `termio/Thread.zig` writer | `Sources/Mantis/PTYProcess.swift` (reader `Thread` + serial writer queue) |
| `renderer/Thread.zig` wakeups | coalesced `scheduleRedraw()` in `TerminalView.swift` |
| `renderer/Metal.zig` + atlas | CoreText/CoreGraphics renderer in `TerminalView.draw` (Metal is on the roadmap) |
| `font/sprite/` | `TerminalView.drawSprite` (box drawing, blocks, shades, rounded corners) |
| `macos/` embedded apprt | `Sources/Mantis/App.swift` (windows, native tabs, splits, menus) |
| `config/Config.zig` | `Sources/Mantis/Config.swift` (same `key = value` syntax, `--key=value` flags, `-e`) |
