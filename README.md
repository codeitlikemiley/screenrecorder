# ScreenRecorder (`sr`)

A macOS app with a CLI and MCP server for screen recording, annotation, and full AI-agent computer control of native macOS applications.

---

## Table of Contents

- [Installation](#installation)
- [Architecture](#architecture)
- [Agent Automation Loop](#agent-automation-loop)
- [CLI Reference](#cli-reference)
  - [status](#status)
  - [screenshot](#screenshot)
  - [detect](#detect)
  - [windows](#windows)
  - [app](#app)
  - [browser](#browser)
  - [input](#input)
  - [ax](#ax)
  - [annotate](#annotate)
  - [record](#record)
  - [session](#session)
  - [screen](#screen)
  - [tool](#tool)
  - [shell](#shell)
- [MCP Server Tools](#mcp-server-tools)
- [Accessibility Permission](#accessibility-permission)
- [Safety Gate](#safety-gate)

---

## Installation

The `sr` CLI ships inside the ScreenRecorder app bundle.

```bash
# Add to your PATH (adjust version as needed)
export PATH="/Applications/ScreenRecorder.app/Contents/MacOS:$PATH"

# Or symlink
ln -s /Applications/ScreenRecorder.app/Contents/MacOS/sr /usr/local/bin/sr

# Verify
sr status
```

The app must be running for CLI commands to work (the CLI talks to the app over a local JSON-RPC socket on port 19820).

---

## Architecture

```
AI Agent / MCP Client
       │
       ▼
 MCP Server (stdio)          ← for Cursor, Claude Desktop, etc.
       │
       ▼
  AgentRouter (JSON-RPC)     ← single dispatcher for all commands
  ┌────────────────────────────────────────┐
  │  AccessibilityBridge (AX API)          │
  │  InputSynthesizer    (CGEvent)         │
  │  VisionOCR           (screenshot+OCR) │
  └────────────────────────────────────────┘
       │
       ▼
   sr CLI (ArgumentParser)  ← for terminal / agent shell use
```

The CLI and MCP server are both thin clients over the same JSON-RPC dispatcher. Every capability available via the CLI is also available via MCP, and vice versa.

---

## Agent Automation Loop

This is the core pattern for AI-driven native app automation:

```
1. DISCOVER  →  sr windows --json                        # find window IDs & bounds
                sr app list --json                       # what apps are running?

2. LAUNCH    →  sr app launch "Safari"                   # launch in background (default)
                sr app launch "Safari" --activate        # launch and focus it
                sr app activate "Safari"                 # bring existing app to front

3. CAPTURE   →  sr screenshot --window "Safari"          # get current visual state
                                                         # auto-caps at 4.9 MB, JPEG fallback

4. DETECT    →  sr detect --window "Safari" --json       # Vision OCR → text + bounding boxes
                sr ax actionable --app "Safari" --json   # AX API → all clickable elements + coords

5. INTERACT  →  sr input click <x> <y>                   # click by coordinate
                sr ax press --app "Safari" --title "Go"  # click by element label (most reliable)
                sr input type-to-field \
                  --field "Address and Search Bar" \
                  --text "https://youtube.com" \
                  --app "Safari"                         # find field + type atomically

6. VERIFY    →  sr screenshot --window "Safari"          # confirm the result
```

### Choosing Between `detect` and `ax actionable`

| Method | Best For | Reliability |
|--------|----------|-------------|
| `sr detect` | Reading visible text, finding labels | Good for text elements |
| `sr ax actionable` | Buttons, text fields, menus, native chrome | More reliable for interactive elements |
| Both together | Maximum coverage | Best approach |

---

## CLI Reference

All commands talk to the running app over `localhost:19820`. Override with `--port`.

---

### `status`

```bash
sr status          # check if app is running
sr status --json   # JSON output
```

---

### `screenshot`

Capture a screenshot. **By default, automatically caps output at 4.9 MB** (just under the 5 MB API limit) by converting to JPEG and reducing quality if needed.

```bash
sr screenshot                              # full screen
sr screenshot --window "Safari"            # specific app window
sr screenshot --window-id 12345            # by window ID
sr screenshot --region 100,200,800,600     # x,y,width,height region
sr screenshot -o ~/Desktop/shot.png        # save to file
sr screenshot --clean                      # without annotations overlay
sr screenshot --base64                     # print base64 to stdout

# Size control (important for AI agents)
sr screenshot --quality 0.8               # JPEG at 80% quality (~300-800 KB)
sr screenshot --scale 0.5                 # 50% resolution (fast, small)
sr screenshot --max-bytes 4500000         # custom byte cap
sr screenshot --window "Safari" --quality 0.8 --scale 0.75  # combined
```

**Response includes:** `file` path, `width`, `height`, `size_bytes`

---

### `detect`

Vision OCR: capture a screenshot and identify all text elements with bounding boxes and center coordinates.

```bash
sr detect                               # full screen OCR
sr detect --window "Safari"             # specific window
sr detect --window-id 12345             # by window ID
sr detect --region 100,200,800,600      # region only
sr detect --min-confidence 0.8          # stricter confidence filter
sr detect --json                        # JSON output
```

**JSON output per element:**
```json
{
  "text": "Search",
  "confidence": 0.98,
  "bounds": { "x": 100, "y": 200, "width": 300, "height": 40 },
  "center": { "x": 250, "y": 220 }
}
```

Use `center.x` and `center.y` directly with `sr input click`.

---

### `windows`

List on-screen windows with their bounds and IDs.

```bash
sr windows                     # all visible windows
sr windows --app "Safari"      # filter by app name
sr windows --focused           # only the frontmost window
sr windows --json              # JSON output
```

**JSON output per window:**
```json
{
  "id": 1234,
  "app": "Safari",
  "title": "YouTube – Google Chrome",
  "bounds": { "x": 0, "y": 0, "width": 1440, "height": 900 }
}
```

---

### `app`

Launch, activate, and list macOS applications.

```bash
sr app launch "Safari"                     # launch in background (default)
sr app launch "Safari" --activate          # launch and focus it
sr app launch "com.apple.Safari"           # by bundle ID
sr app activate "Safari"                   # bring to front (waits for focus, max 2s)
sr app list                                # list all running apps
sr app list --json
```

> **Note:** `launch` now defaults to background launch (`activate=false`) so it will not steal focus. `activate` and `launch --activate` still wait until the app is frontmost before returning.

---

### `browser`

Browser automation for web pages. Chromium uses the DevTools Protocol; Safari uses `safaridriver`/WebDriver. Prefer this over OCR/mouse control for webpages.

```bash
sr browser launch --url https://example.com                    # isolated Chrome profile on port 9222
sr browser launch-and-open https://example.com                # best first step for webpage tasks
sr browser launch --backend safari --app Safari --url https://example.com
sr browser tabs --json                                         # list tabs
sr browser click 'button[type="submit"]'                       # DOM click by CSS selector
sr browser type 'input[name="q"]' 'screen recorder'            # set input value via DOM
sr browser eval 'document.title'                               # inspect page state with JS
sr browser screenshot -o /tmp/page.png                         # capture page via browser renderer
```

> **Note:** Browser automation does not need your real mouse cursor or the frontmost app. It is the preferred control path for web pages. Keep desktop input tools for native browser chrome, OS dialogs, and non-browser apps. Safari requires `safaridriver`; on a new machine you may need to run `safaridriver --enable` once.
>
> Routing rule: if the instructed app is Safari, Chrome, Chromium, Brave, or Edge and the task is inside webpage content, use `browser.*` first. Use `app.*`, `input.*`, or `ax.*` only for browser chrome, permission prompts, downloads, file pickers, or OS-level UI.

---

### `input`

Synthesize mouse and keyboard input. Requires [Accessibility permission](#accessibility-permission).

```bash
sr input check-access                            # verify permission is granted
```

#### Mouse

```bash
sr input click 500 300                           # left click
sr input click 500 300 --count 2                 # double-click
sr input right-click 500 300                     # right click
sr input double-click 500 300                    # explicit double-click
sr input drag 100 200 500 300                    # drag from (100,200) to (500,300)
sr input scroll 500 300 --dy -300                # scroll down (negative = down)
sr input scroll 500 300 --dx 100                 # scroll right
sr input move 500 300                            # move cursor (no click)
```

#### Keyboard

```bash
sr input type "hello world"                      # type text
sr input type "hello" --interval-ms 100          # slower typing (default: 50ms/char)
sr input key return                              # press a key
sr input key space
sr input key escape
sr input key tab
sr input key delete
sr input key f5
sr input hotkey cmd+c                            # keyboard shortcut
sr input hotkey cmd+shift+s
sr input hotkey cmd+t
sr input type "hello" --app "Safari"            # deliver to Safari without focusing it
sr input hotkey cmd+l --app "Safari"            # background hotkey delivery
```

#### Smart Input (AX-powered)

```bash
# Find a text field by label/placeholder, focus it, and type — atomically
sr input type-to-field \
  --field "Address and Search Bar" \
  --text "https://youtube.com" \
  --app "Safari"

sr input type-to-field \
  --field "Search" \
  --text "lakers vs pistons" \
  --app "Safari" \
  --interval-ms 80
```

#### Click by Text (OCR-powered)

```bash
sr input click-text "Submit"                     # find text on screen → click it
sr input click-text "Go" --window "Safari"       # search within specific window
```

Window-targeted screenshots (`sr screenshot --window ...`) do not require that window to become frontmost. Background input delivery works best for click, type, key, hotkey, and scroll. Drag still requires focus.

Falls back to AX API when OCR finds the element but cannot determine its center coordinates.

---

### `ax`

Accessibility API commands — the most reliable way to interact with native macOS apps. Works directly on the UI element tree without coordinates or OCR.

Requires [Accessibility permission](#accessibility-permission).

```bash
# Explore the UI tree
sr ax tree --app "Safari"                        # full element tree (depth 3)
sr ax tree --app "Safari" --max-depth 5          # deeper tree
sr ax tree --app "Finder" --json

# Find specific elements
sr ax find --app "Safari" --title "Search"       # by label/title
sr ax find --app "Safari" --role AXTextField     # all text fields
sr ax find --app "Safari" --role AXButton        # all buttons
sr ax find --app "Safari" --role AXMenuItem --max-results 20

# Interact with elements
sr ax press --app "Safari" --title "Go"          # press/click by title
sr ax press --app "Safari" --title "File" --action AXPress

# Set values in text fields, checkboxes, sliders
sr ax set-value --app "Safari" \
  --title "Address and Search Bar" \
  --value "https://youtube.com"

# What is focused right now?
sr ax focused
sr ax focused --json

# List ALL actionable elements (buttons, fields, menus) with coordinates
sr ax actionable --app "Safari"
sr ax actionable --app "Safari" --max-results 50 --json
```

**Example `ax actionable` output:**
```
🎯 23 actionable element(s):
──────────────────────────────
  [AXButton] Back  @ (44, 52)  [AXPress]
  [AXButton] Forward  @ (70, 52)  [AXPress]
  [AXTextField] Address and Search Bar  @ (720, 52)  [AXPress, AXConfirm]
  [AXMenuItem] File  @ (50, 11)  [AXPress]
  ...
```

You can target by `--app`, `--bundle-id`, or `--pid`.

---

### `annotate`

Draw visual annotations on screen. Useful for highlighting UI elements in documentation and demos.

```bash
# Mode
sr annotate activate                             # enter annotation mode
sr annotate deactivate                           # exit annotation mode

# Draw shapes
sr annotate add --arrow 100,200,300,400          # arrow from→to
sr annotate add --rect 50,50,200,150             # rectangle (x,y,w,h)
sr annotate add --ellipse 50,50,200,150          # ellipse/circle
sr annotate add --line 100,200,300,400           # straight line
sr annotate add --text "Click here" --at 200,100 # text label

# Style options (add to any shape)
sr annotate add --rect 50,50,200,150 --color blue --width 3
sr annotate add --text "Important" --at 300,200 --color yellow --width 18

# Colors: red, blue, green, yellow, white, orange, cyan, magenta

# Raw JSON (for complex multi-annotation adds)
sr annotate add --json '[
  {"type":"arrow","from":{"x":0,"y":0},"to":{"x":100,"y":100},"color":"red"},
  {"type":"rectangle","origin":{"x":50,"y":50},"size":{"width":200,"height":100}}
]'

# Manage
sr annotate list                                 # list current annotations
sr annotate undo                                 # undo last annotation
sr annotate redo                                 # redo
sr annotate clear                                # clear all
```

---

### `record`

Record screen to video.

```bash
sr record start                                  # start recording
sr record start --output ~/Desktop/demo.mp4      # custom output
sr record pause                                  # pause
sr record resume                                 # resume
sr record stop                                   # stop and finalize
```

---

### `session`

Manage named recording/annotation sessions.

```bash
sr session new --name "demo"                     # create new session
sr session list                                  # list all sessions
sr session switch <id>                           # switch to session
sr session save                                  # save current session
sr session export --format mp4                   # export session
sr session delete <id>                           # delete session
```

---

### `screen`

Get information about connected displays.

```bash
sr screen                                        # list all screens
sr screen --json                                 # JSON output
```

---

### `tool`

Configure the annotation drawing tool.

```bash
sr tool pen                                      # switch to pen
sr tool arrow                                    # switch to arrow
sr tool rect                                     # switch to rectangle
sr tool ellipse                                  # switch to ellipse
sr tool text                                     # switch to text
sr tool highlighter                              # switch to highlighter

sr tool color red                                # set color
sr tool color "#FF5500"                          # hex color

sr tool width 3                                  # set line width
```

---

### `shell`

Execute a shell command via the app process and return its output.

```bash
sr shell "echo hello"
sr shell "ls -la /tmp"
sr shell --timeout 10 "npm test"
sr shell --json "git status"
```

---

## MCP Server Tools

When used as an MCP server (e.g. with Claude Desktop or Cursor), all capabilities are exposed as MCP tools:

### Screen & Vision
| Tool | Description |
|------|-------------|
| `screen_recorder_status` | Check app status |
| `screen_recorder_screen_info` | Get display info |
| `screen_recorder_list_windows` | List windows with bounds |
| `screen_recorder_focused_window` | Get frontmost window |
| `screen_recorder_detect_elements` | Vision OCR element detection |
| `screen_recorder_screenshot` | Capture screenshot (with scale/quality/max_bytes) |

### Recording
| Tool | Description |
|------|-------------|
| `screen_recorder_start` | Start recording |
| `screen_recorder_stop` | Stop recording |
| `screen_recorder_pause` | Pause recording |
| `screen_recorder_resume` | Resume recording |

### Annotations
| Tool | Description |
|------|-------------|
| `screen_recorder_annotate` | Add annotations (arrow/rect/ellipse/line/text) |
| `screen_recorder_annotate_activate` | Enter annotation mode |
| `screen_recorder_annotate_deactivate` | Exit annotation mode |
| `screen_recorder_annotate_list` | List current annotations |
| `screen_recorder_annotate_undo` | Undo last annotation |
| `screen_recorder_annotate_redo` | Redo annotation |
| `screen_recorder_annotate_clear` | Clear all annotations |
| `screen_recorder_tool` | Set drawing tool |
| `screen_recorder_tool_color` | Set tool color |
| `screen_recorder_tool_width` | Set tool width |

### Sessions
| Tool | Description |
|------|-------------|
| `screen_recorder_session_new` | Create session |
| `screen_recorder_session_list` | List sessions |
| `screen_recorder_session_switch` | Switch session |
| `screen_recorder_session_delete` | Delete session |
| `screen_recorder_session_save` | Save session |
| `screen_recorder_session_export` | Export session |

### Computer Control (Input)
| Tool | Description |
|------|-------------|
| `screen_recorder_click` | Left click at coordinates |
| `screen_recorder_right_click` | Right click |
| `screen_recorder_double_click` | Double click |
| `screen_recorder_drag` | Click-drag from→to |
| `screen_recorder_scroll` | Scroll at coordinates |
| `screen_recorder_move_mouse` | Move cursor |
| `screen_recorder_type_text` | Type text |
| `screen_recorder_press_key` | Press a key |
| `screen_recorder_hotkey` | Keyboard shortcut |
| `screen_recorder_click_element` | Click by text (OCR + AX fallback) |

### App Control
| Tool | Description |
|------|-------------|
| `screen_recorder_launch_app` | Launch app (background by default, optional activate) |
| `screen_recorder_activate_app` | Bring app to front (waits for focus) |
| `screen_recorder_list_apps` | List running apps |

### Browser Automation
| Tool | Description |
|------|-------------|
| `screen_recorder_browser_status` | Check DevTools endpoint reachability |
| `screen_recorder_browser_launch` | Launch Chromium browser with remote debugging |
| `screen_recorder_browser_launch_and_open` | Ensure browser automation is ready, then open URL |
| `screen_recorder_browser_tabs` | List browser tabs |
| `screen_recorder_browser_open_tab` | Open a new browser tab |
| `screen_recorder_browser_activate_tab` | Activate a browser tab |
| `screen_recorder_browser_navigate` | Navigate a tab to a URL |
| `screen_recorder_browser_eval` | Evaluate JavaScript in a tab |
| `screen_recorder_browser_click` | Click a DOM element by CSS selector |
| `screen_recorder_browser_type` | Set a DOM element value by CSS selector |
| `screen_recorder_browser_press_key` | Dispatch a key to the page's active element |
| `screen_recorder_browser_screenshot` | Capture a browser-rendered screenshot |

### Accessibility API (AX)
| Tool | Description |
|------|-------------|
| `screen_recorder_check_accessibility` | Check AX permission |
| `screen_recorder_ax_tree` | Get UI element tree |
| `screen_recorder_ax_find` | Find elements by title or role |
| `screen_recorder_ax_press` | Press/click element by title |
| `screen_recorder_ax_set_value` | Set value of a text field, checkbox, etc. |
| `screen_recorder_ax_focused` | Get currently focused element |
| `screen_recorder_ax_actionable` | List all actionable elements with coordinates |

### Safety & Shell
| Tool | Description |
|------|-------------|
| `screen_recorder_safety_settings` | Get current safety gate settings |
| `screen_recorder_safety_configure` | Configure safety constraints |
| `screen_recorder_run_command` | Execute shell command |
| `screen_recorder_usage` | Get API usage stats |

---

## Accessibility Permission

Input synthesis and AX API features require Accessibility permission.

1. Open **System Settings → Privacy & Security → Accessibility**
2. Enable **ScreenRecorder**

Verify from the CLI:
```bash
sr input check-access
sr ax focused     # will error with a helpful message if not granted
```

---

## Safety Gate

All computer control actions pass through a configurable safety gate that:
- Logs every synthesized input event
- Can enforce rate limits
- Can require explicit confirmation for destructive actions
- Can enforce an execution mode so automation does not steal focus or your active app

Configure via:
```bash
# Via CLI
sr safety status
sr safety mode background_safe
sr safety mode foreground

# Via MCP
screen_recorder_safety_configure
screen_recorder_safety_settings
```

Execution modes:
- `foreground`: classic automation behavior, including focus changes and frontmost input.
- `background_safe`: default. Blocks focus-stealing actions, real cursor movement, and frontmost/global input. Use targeted app/PID input instead.
- `background_strict`: blocks everything from `background_safe` plus window moves/resizes/minimize/restore and disruptive app lifecycle actions.

---

## MCP Server Configuration

Add to your MCP client config (e.g. `~/.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "screenrecorder": {
      "command": "/Applications/ScreenRecorder.app/Contents/MacOS/sr",
      "args": ["mcp"]
    }
  }
}
```

The app must be running before the MCP connection is established.
