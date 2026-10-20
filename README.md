# SSH Button Terminal

An AutoHotkey v2 GUI that docks a real [KiTTY](https://www.9bis.net/kitty/) SSH session inside the window, with programmable command buttons and a shared variable panel.

## Features
- KiTTY terminal embedded in the GUI (full interactivity, password typed in the terminal)
- Command box for typing commands directly (Enter to send)
- Buttons organized into groups, each sending one or more commands
- `{VARIABLE}` placeholders filled from a Variables panel, e.g. `curl -X GET http://{IP}/`
- Built-in variables `{HOST}` and `{USER}` from the connection bar
- Host drop-down filled from the `HostList` array at the top of the script
- Cancel button sends Ctrl+C
- Multi-command buttons with `#sleep <ms>` pauses and `#` comment lines
- Button editor: create, edit, delete, duplicate, reorder, rename/delete groups
- Import/export button sets as JSON
- Type or paste send modes

## Requirements
- Windows
- [AutoHotkey v2](https://www.autohotkey.com/)
- KiTTY. Set your own launch command in `Connect()` (the `cmd := "placeholder"` line) and set `KittyExeName` at the top of the script to its process name.

## Usage
1. Run `SSHButtonTerminal.ahk`.
2. Edit `HostList` at the top of the script, then pick a Host, enter a User and press **Connect**. Type your password in the terminal.
3. Select a variable, enter its value and press **Set**.
4. Click buttons, or type in the Command box and press Enter.

Settings, buttons and variables are saved to `SSHButtonTerminal.json` next to the script.

## Command syntax
| Syntax | Meaning |
| --- | --- |
| `{NAME}` | Replaced with the variable's value (send aborts if empty) |
| `{{` / `}}` | Literal `{` / `}` (e.g. `${{HOME}}` sends `${HOME}`) |
| One command per line | Each line is sent separately |
| `#sleep 500` | Pause 500 ms between lines |
| `# text` | Comment, ignored |

## Known limitations
- No scrolling in the button area; very large groups get clipped.
- KiTTY's host-key prompt for a new server may appear behind the main window.
