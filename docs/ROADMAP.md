# Mantis roadmap: features that could be added

Items are grouped by area and tagged by effort: **S** (hours), **M** (days), **L** (a week or more).
✅ marks features that already exist.

## Already in Mantis v0.1
✅ vt100.net parser (CSI/ESC/OSC/DCS, colon sub-params, UTF-8) · ✅ primary/alt screen, scroll regions, origin
mode, insert mode, tabs, DEC line drawing · ✅ SGR: bold/dim/italic/underline (single/double/curly)/strike/
overline/inverse/hidden, 16/256/truecolor · ✅ wide CJK/emoji + combining marks · ✅ 10k-line ring-buffer
scrollback with pinned viewport · ✅ DSR/DA/XTVERSION/DECRQM/OSC 10/11/4 queries · ✅ OSC 0/2 title, OSC 7 cwd
(proxy icon), OSC 8 hyperlinks, OSC 52 clipboard write, OSC 9/777 notifications · ✅ mouse reporting
(X10/normal/button/any, SGR 1006), focus events, bracketed paste, synchronized output (2026), alternate scroll
· ✅ IME/dead keys (NSTextInputClient), option-as-alt · ✅ selection (drag, word, line, rectangular ⌥-drag),
copy-on-select · ✅ ⌘F search with highlights · ✅ ⌘-click links (OSC 8 + auto-detected URLs) · ✅ native tabs,
splits (⌘D / ⇧⌘D), close confirmation for running jobs · ✅ unsafe-paste protection · ✅ sprite box drawing &
block elements · ✅ minimum-contrast · ✅ `key = value` config file + CLI flags + `-e`

## Added in v0.2 (quick wins)
✅ Hint mode (⇧⌘H) for URLs, paths, git hashes and IPs, including soft-wrapped lines · ✅ ⌘-click `file:line:col` →
editor (`editor = code -g {file}:{line}:{col}`), resolving relative paths against the shell's cwd · ✅ Copy as HTML/RTF
with colors (⌥⌘C) · ✅ Editable paste preview, with "Paste as One Line" · ✅ Highlight rules (`highlight = REGEX=#color`) ·
✅ Line bookmarks (⌘B, ⌘↑/⌘↓) · ✅ Secure Keyboard Entry, held only while the app is active · ✅ Badge text
(`badge = {host}`, ⌥⌘B per pane) · ✅ Dimmed unfocused splits (`unfocused-split-opacity`) · ✅ Cursor trail animation

## Added in v0.3
✅ Settings window (⌘,) with granular control, live apply and autosave to the config file · ✅ 7 built-in themes ·
✅ Visual effects (Matrix, CRT, Starfield, Snow, Fireflies, Aurora, Synthwave) on their own layer, with auto-pause ·
✅ Live config reload (⇧⌘,) applied to open terminals · ✅ Layered pane rendering (background → effect → text)

✅ Session highlights (PDF-style marker): 5 colors, notes, jump/list, Markdown export, text-verified anchors

**Next ideas here:** persist highlights across launches (save with scrollback) · import iTerm2 theme files · per-profile settings (e.g. a red-tinted "prod" profile) ·
user GLSL/Metal shaders · keybinding editor tab · settings search field

## 1. Performance
| Feature | Effort | Notes |
|---|---|---|
| **Metal renderer** with a glyph texture atlas and instanced cell quads | L | Replace CoreGraphics drawing |
| Dedicated render thread + CVDisplayLink pacing | M | Draw at the display refresh rate, off the main thread |
| Cache row → CTLine and redraw only dirty rows | S | Large win while staying on CoreGraphics |
| SIMD UTF-8 decode until the next ESC | M | Swift `SIMD16<UInt8>` |
| Page-based cell storage (contiguous, style-interned) | L | Cut the per-cell `Character`, use a style ID + grapheme side table |
| Recycle `Row` allocations when scrolling | S | Profiling shows scrolling at about half the speed of plain printing |
| Benchmarks in CI (`vtebench`-style) | S | Track parser and render throughput per commit |

## 2. Terminal protocol completeness
| Feature | Effort |
|---|---|
| **Kitty keyboard protocol** (CSI u, disambiguate/report-events flags) | M |
| **Kitty graphics protocol** (inline images, placements, animation) | L |
| Sixel images | M |
| Text reflow on resize (rewrap soft-wrapped lines) | M |
| Grapheme clustering per Unicode 15/16 (ZWJ emoji families, mode 2027) | M |
| Underline color (SGR 58), blink rendering | S |
| DECSLRM left/right margins, DECSCA protection, DECRQSS | M |
| tmux control mode (`tmux -CC`), with tmux windows as native tabs | L |
| OSC 133 semantic prompts → jump to prompt, select command output | M |
| OSC 4/10/11 *set* sequences (theme changes from apps) | S |
| XTGETTCAP / ship a `mantis` terminfo entry | S |

## 3. Fonts & text
| Feature | Effort |
|---|---|
| Ligatures and OpenType features (`font-feature = calt, ss01`) via CTLine shaping per run | M |
| Font fallback chain config (`font-family` repeated) and variable-font axes | S |
| Built-in Nerd Font symbol map and Powerline sprite glyphs | M |
| `adjust-cell-height`, `adjust-underline-position`, thicken/font smoothing options | S |
| Bold rendered as a brighter color vs. bold font, as an option | S |

## 4. Window management & UX
| Feature | Effort |
|---|---|
| **Quick Terminal**: a global-hotkey drop-down (Quake-style) panel | M |
| Split resize/navigation by direction (⌘⌥ arrows), zoom a split, drag to rearrange | M |
| Command palette (fuzzy list of all actions) | M |
| Configurable **keybindings** (`keybind = cmd+shift+e=split_right`) | M |
| Theme library (`theme = …`, light/dark auto-switch) | S |
| Background blur and image, window padding balance, transparent titlebar styles | S |
| Window state restoration (tabs, splits, cwd) across launches | M |
| New tab/split inherits the cwd (OSC 7 is already parsed) | S |
| Secure keyboard entry, `confirm-close-surface`, bell options (audible/visual/badge) | S |
| Scrollbar UI, scrollback export to file | S |
| Inspector (debug overlay of terminal state, keystrokes, cells) | M |

## 5. Shell integration
| Feature | Effort |
|---|---|
| Auto-inject zsh/bash/fish scripts (cwd reporting, prompt marks, cursor shape at prompt) | M |
| Click to move the cursor at the prompt; select command output; "copy last output" | M |
| Notify when a long-running command finishes and the window is unfocused | S |
| SSH terminfo propagation helper | S |

## 6. Platform & distribution
| Feature | Effort |
|---|---|
| Linux GTK4 frontend over the same `MantisCore` (Swift runs on Linux) | L |
| `libmantis-vt` C API so other apps can embed the core | M |
| Sparkle auto-update, notarized signed builds, Homebrew cask | S |
| AppleScript/App Intents/Shortcuts automation | M |
| Accessibility: VoiceOver text exposure (NSAccessibility text area) | M |

## 7. Differentiators
| Idea | Effort |
|---|---|
| AI command assist: explain errors or suggest commands, opt-in, local-first | M |
| Block-based output (each command is a collapsible block, built on OSC 133) | L |
| Session recording and replay (asciicast export) | S |
| Collaborative shared session (read-only viewer over WebSocket) | L |
| Per-split environment profiles (prod = red tint, staging = yellow) | S |
