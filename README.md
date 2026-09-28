<p align="center">
  <img src="assets/banner.svg" alt="UpsideDown: one key, two computers, one monitor" width="100%">
</p>

<p align="center">
  <b>Flip your monitor over to your other computer with one hotkey.</b><br>
  PC ⇄ Mac, laptop or console. No KVM switch. No reaching for the monitor's buttons. No extra hardware.<br>
  <sub>(It switches the monitor's <i>input</i>. Your screen doesn't actually turn upside down.)</sub>
</p>

<p align="center">
  <a href="#one-click-setup"><img alt="Windows 10/11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4"></a>
  <a href="https://www.autohotkey.com"><img alt="AutoHotkey v2" src="https://img.shields.io/badge/AutoHotkey-v2-334455"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-a855f7"></a>
</p>

---

## Why

You have one great monitor and two computers plugged into it. Switching means fumbling
for the tiny joystick behind the screen and clicking through menus, every single time.

UpsideDown turns that into **Ctrl + F12**.

## How it works

<p align="center">
  <img src="assets/how-it-works.svg" alt="Press Ctrl+F12, UpsideDown sends a DDC/CI command over the video cable, the monitor switches inputs" width="100%">
</p>

Almost every monitor made in the last 15 years understands **DDC/CI**, a small control
channel that runs over the same HDMI or DisplayPort cable as the picture. It's how
brightness apps talk to your screen. One of its commands, `0x60`, means *"switch input"*.

UpsideDown is a tiny [AutoHotkey](https://www.autohotkey.com) script that sends that command
straight through Windows. It asks the monitor which input it's on and flips to the other one.

- **Fast:** the command goes out in about 0.1 s.
- **Tiny:** one script, no drivers, no background service, no network.
- **Reliable:** retries when the monitor drops a message, and re-sends if a switch doesn't stick.

## One-click setup

1. **Download** this repo: green **Code** button → **Download ZIP**, then unzip it anywhere.
2. **Double-click `install.bat`.**
3. Answer one question: when the screen flips to your other computer, type **y**.

That's it. Press **Ctrl + F12** to flip.

> [!TIP]
> Turn your other computer on and keep it awake before running setup, so you can see it
> when the installer test-flips to it.

### What the installer does

| Step | What happens |
| --- | --- |
| 1. AutoHotkey | Installs [AutoHotkey v2](https://www.autohotkey.com) with `winget` if you don't have it. |
| 2. Detect | Reads which input your PC is on and which inputs your monitor has. |
| 3. Test-flip | Switches to each candidate input for 8 seconds and back, until you confirm the right one. |
| 4. Install | Copies UpsideDown to `%LOCALAPPDATA%\UpsideDown` and saves your settings. |
| 5. Autostart | Adds a shortcut to your Startup folder so UpsideDown runs every time you sign in. |
| 6. Run | Starts UpsideDown right away. Look for the green **H** icon in the system tray. |

Nothing needs admin rights, and nothing is changed outside your user folder.

### Advanced options

Run the installer from a terminal to skip the questions:

```powershell
.\install.ps1 -Other 18 -NoTest        # you already know the other input code
.\install.ps1 -Hotkey "^!m"            # use Ctrl+Alt+M instead of Ctrl+F12
.\install.ps1 -ThisPC 15 -Other 17     # set both inputs yourself
```

## Using it

| Do this | To |
| --- | --- |
| **Ctrl + F12** | Flip the monitor to the other computer, and back again. |
| Double-click the tray icon | Flip, with the mouse. |
| Right-click the tray icon → **Edit settings** | Change the hotkey or input codes. |
| Right-click the tray icon → **Reload** | Apply your changes. |

The keyboard and mouse stay connected to your PC, so **Ctrl + F12 works in both directions**,
even while the monitor is showing the other computer.

## Settings

Everything lives in `%LOCALAPPDATA%\UpsideDown\config.ini`:

```ini
[UpsideDown]
ThisPC=15      ; input code of the PC running UpsideDown
Other=18       ; input code of your other computer
Hotkey=^F12    ; ^ Ctrl   ! Alt   + Shift   # Win
```

### Input codes

These are the standard codes. **Manufacturers don't always follow them**. On some Acer
models, for example, HDMI 2 reports `15`. That's why the installer test-flips instead
of guessing.

| Input | Standard code |
| --- | --- |
| VGA 1 / 2 | 1 / 2 |
| DVI 1 / 2 | 3 / 4 |
| DisplayPort 1 / 2 | 15 / 16 |
| HDMI 1 / 2 | 17 / 18 |
| USB-C | 27 |

## Troubleshooting

<details>
<summary><b>"Your monitor didn't answer"</b></summary>

Turn on **DDC/CI** in your monitor's on-screen menu. It's usually under *System*, *Setup*
or *Other*. Some monitors ship with it off.
</details>

<details>
<summary><b>It flips to a black "No signal" screen, then lands on the right computer a few seconds later</b></summary>

The input code is one off. The monitor is switching to an empty input and then auto-scanning
until it finds your other computer. Run `install.bat` again and pick a different input, or
edit `Other=` in the settings.
</details>

<details>
<summary><b>The switch feels slow</b></summary>

UpsideDown sends the command in about 0.1 s. The rest is the monitor locking onto the new
signal, which usually takes 1 to 3 seconds. You can shorten it:

- Turn off **Auto Source / Input Auto-Detect** in the monitor menu.
- Stop the other computer from sleeping its display (on a Mac: System Settings → Lock Screen).
- DisplayPort usually switches faster than HDMI, because HDMI repeats a copy-protection
  handshake every time.
</details>

<details>
<summary><b>Sometimes it takes two presses</b></summary>

Some monitors ignore commands while they're busy switching. Wait until the picture
settles before pressing again. UpsideDown also re-checks 2.5 s after each flip and
re-sends if the monitor didn't follow.
</details>

<details>
<summary><b>I have more than one monitor</b></summary>

UpsideDown controls your **primary** display. Set the monitor you want to flip as the
main display in *Settings → System → Display*.
</details>

<details>
<summary><b>Can I flip back from the Mac's keyboard?</b></summary>

UpsideDown runs on Windows. On a Mac, [m1ddc](https://github.com/waydabber/m1ddc) (Apple
Silicon) or [BetterDisplay](https://github.com/waydabber/BetterDisplay) can send the
same command, for example `m1ddc set input 15`.
</details>

## Uninstall

Double-click **`uninstall.bat`**. It stops UpsideDown and removes the startup shortcut and
`%LOCALAPPDATA%\UpsideDown`. AutoHotkey stays installed; remove it from *Settings → Apps*
if you don't need it.

## Project layout

```
UpsideDown/
├── install.bat          one-click installer (runs install.ps1)
├── install.ps1          detects inputs, test-flips, installs
├── uninstall.bat        one-click uninstaller
├── uninstall.ps1
├── src/
│   ├── upsidedown.ahk   the switcher (~100 lines)
│   └── config.ini       default settings
└── assets/              README illustrations
```

## Contributing

Bug reports and pull requests are welcome. If UpsideDown doesn't work with your monitor,
please open an issue with the monitor model and what `install.bat` printed.

## License

[MIT](LICENSE). Use it, change it, share it.
