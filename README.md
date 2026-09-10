# BrightBar

**Control external monitor brightness from the macOS menu bar** — DDC/CI for Apple Silicon Macs, with keyboard brightness key support and software dimming below the monitor's minimum.

Free, open source, ~1 MB, no Dock icon, no dependencies.

## Features

- Adjust brightness of external monitors (DisplayPort, USB-C, Thunderbolt, HDMI\*) over **DDC/CI**
- **Keyboard brightness keys** (F1/F2 / ☀︎ keys) control whichever monitor the mouse cursor is on, with the native macOS on-screen bezel
- **Software dimming**: slide below 0 % to dim further than the hardware allows
- Multiple monitors, with an "All Displays" master slider
- Control Center–style popover, Launch at Login, `--probe` diagnostics

## Install

```bash
git clone https://github.com/<you>/brightbar && cd brightbar
./scripts/install.sh        # builds, copies to /Applications, opens the app
```

Requires an Apple Silicon Mac running macOS 13+. On first launch grant **Accessibility** access (System Settings → Privacy & Security) so the brightness keys can be intercepted. Enable **Launch at Login** from the right-click menu.

## Troubleshooting

- Turn on **DDC/CI** in your monitor's on-screen menu.
- Some docks and HUB/KVMs don't forward DDC; try a direct cable. \*HDMI on some Macs does not carry DDC.
- Run `.build/release/BrightBar --probe` to see what the app detects.

## How it works

Apple Silicon Macs expose the display's I²C bus via the private `IOAVService` IOKit API; BrightBar sends VCP 0x10 (luminance) commands over it. Software dimming scales the display's gamma table via CoreGraphics and is reverted on quit.

## License

MIT
