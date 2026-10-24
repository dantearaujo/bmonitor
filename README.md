<p align="center"><a href="README.pt-BR.md">🇧🇷 Leia em português</a></p>

<p align="center"><img src="docs/icon.png" width="128" alt="bmonitor icon"></p>

<h1 align="center">bmonitor</h1>

<p align="center">Monitor and remote-control an iPhone running <b>Blackmagic Camera</b> from your Mac.<br>
Live video and audio over Wi‑Fi, about 0.3 s behind real time.</p>

<p align="center"><img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" />&nbsp;<img alt="Swift" src="https://img.shields.io/badge/swift-6.0-orange" />&nbsp;<img alt="License" src="https://img.shields.io/badge/license-MIT-green" />&nbsp;<img alt="Latest release" src="https://img.shields.io/github/v/release/dantearaujo/bmonitor" /></p>

<p align="center">
  <a href="https://www.buymeacoffee.com/dantearaujo">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="42" alt="Buy Me a Coffee" />
  </a>
</p>

<h3 align="center"><a href="https://github.com/dantearaujo/bmonitor/releases/latest/download/bmonitor.dmg">⬇️ Download bmonitor for Mac</a></h3>

<p align="center"><sub>Latest version · macOS 14 Sonoma or later · Apple Silicon and Intel · <a href="#install">how to install</a> · <a href="https://bmonitor.app">bmonitor.app</a></sub></p>

<p align="center"><b>⚠️ Public beta (0.10.2).</b> It works every day on the author's setup, but so far it has been tested on two Macs (macOS 26 and macOS 14) and one iPhone. Expect rough edges and <a href="https://github.com/dantearaujo/bmonitor/issues">report them</a>.</p>

The app speaks English and Brazilian Portuguese, following your Mac's language.

**On a handheld:** a test build for SteamOS turns a Lenovo Legion Go S into the same monitor and remote control, opened from the Steam library. See [bmonitor for SteamOS](https://bmonitor.app/steamos/) or [download the 0.1.1 Flatpak](https://github.com/dantearaujo/bmonitor/releases/tag/deck-v0.1.1-beta).

---

## What it does

You record yourself with an iPhone on a tripod. bmonitor turns the Mac next to it into the camera's monitor and remote control, without a second iPhone or iPad.

- **Monitor:** live video in a regular Mac window, landscape or portrait, with a recording tally (red border), timecode, remaining recording time, and signal status. Framing grids: thirds, golden ratio, center cross, and more. Safe areas for vertical video show what Instagram and Facebook, TikTok and YouTube Shorts cover, plus the profile grid crop (3:4) and a center square (1:1).
- **Audio:** the active microphone's name and an L/R peak meter styled after Blackmagic's own (green, yellow, red), plus the camera's sound on the Mac, muted by default.
- **Copy on the Mac:** optional, one button next to record. Each take is also saved on the Mac from the live stream, at the camera's resolution and about 8 Mb/s, named after the iPhone clip, in `~/Movies/bmonitor`. The original stays on the iPhone.
- **Remote control:** start and stop recording, ISO, shutter (speed or angle), white balance with light presets, tint, focus (click the video to focus there), zoom, lens, stabilization, recording format (resolution, frame rate, codec, color space), audio input, and audio gain (with an external mic; the iPhone's built-in mic doesn't accept gain changes).
- **Script:** a panel inside the monitor window, beside the video or, with the video in landscape, above or below it. Paste or open your text (Markdown works), and it follows along as you speak, using the camera's sound; speech recognition runs on the Mac. Pop it out into its own window and dock it back with one click.
- **Keyboard:** one key per control (`I` ISO, `S` shutter, `P` frame rate, `W` white balance, `T` tint, `L` lens, `A` audio, `M` mute, `G` grid, `Z` safe area, `F` focus now, `K` recording format), `⌥↑` `⌥↓` for audio gain, `⌘R` to record, `⌘→` to rotate, `⌘2` to show or hide the script. `⌘/` shows them all.
- **First run:** while it looks for the iPhone, bmonitor shows which app to open (Blackmagic Camera, not the built-in Camera), the settings to turn on, and whether the Mac is blocking Local Network access.
- **Webcam:** turn on **Camera › Use as Webcam** and the iPhone becomes a camera called "bmonitor" in Meet, Zoom, FaceTime and any other app, with Blackmagic Camera's manual exposure, white balance and LUT. Video only: keep using the microphone you already use. The picture runs at least as far behind as the monitor, about 0.3 s. The first time, macOS asks you to allow the camera extension, and bmonitor shows you where.
- **Updates itself:** when a new version is out, bmonitor shows what changed and asks before installing. It checks when you open it and once a day. You can also use **bmonitor › Check for Updates…**.
- **Readable from 3 m:** status lives in the top corners and stays large. The control bar appears when you move the mouse and hides after 3 s.

## Requirements

| | |
|---|---|
| Mac | macOS 14 Sonoma or later, Apple Silicon or Intel (tested on macOS 26 Tahoe with Apple Silicon and on macOS 14 Sonoma; Intel Macs and macOS 15 are untested in this beta, so please report how it goes) |
| iPhone | [Blackmagic Camera](https://apps.apple.com/app/blackmagic-camera/id6449580241) (free), tested with version 3.5 |
| Network | Mac and iPhone on the **same Wi‑Fi network** |

## Install

1. [Download bmonitor.dmg](https://github.com/dantearaujo/bmonitor/releases/latest/download/bmonitor.dmg), always the latest version. Older versions live in [Releases](https://github.com/dantearaujo/bmonitor/releases).
2. Open the `.dmg` and drag **bmonitor** to **Applications**.
3. Open bmonitor. macOS asks to confirm opening an app downloaded from the internet: click **Open**. bmonitor is signed and notarized by Apple.
4. When macOS asks to let bmonitor **find devices on your local network**, click **Allow**. Without this, the app can't see the iPhone.

## Set up the iPhone

Do this once in the Blackmagic Camera app:

1. Open Blackmagic Camera and go to its settings.
2. Set **Remote Camera Control** to **Remote Camera**. If it asks what the camera is available for, allow both control and monitoring.
3. In **Network Access**, turn on the **HTTP server**.
4. Allow Blackmagic Camera on the local network: iOS **Settings › Privacy & Security › Local Network › Blackmagic Camera** on.

Every time you record:

- connect the iPhone and the Mac to the same Wi‑Fi;
- leave Blackmagic Camera open **on the camera screen**;
- turn off auto-lock (iOS **Settings › Display & Brightness › Auto-Lock › Never**), or the stream stops when the screen locks.

Then open bmonitor. It finds the iPhone by itself and shows the video in a few seconds. With more than one iPhone on the network, it asks which one to use.

## What bmonitor changes on your iPhone

bmonitor receives the video through Blackmagic Camera's **live stream** feature, the same one used to stream to YouTube or other platforms:

- On the first connection it adds a custom streaming platform called **Mac Monitor SRT** to Blackmagic Camera. It only sends it again if your Mac's address changes.
- While bmonitor is open, that platform is the active one and the iPhone streams to your Mac.
- When you quit bmonitor (`⌘Q`, closing the window, or Ctrl‑C in a terminal), it stops the stream and **restores the platform you had before**.
- If bmonitor is force-quit or crashes, the iPhone keeps pointing at the Mac. Open bmonitor and quit it normally once, and your original platform comes back.

Recording stays on the iPhone, in the quality you chose there. The stream to the Mac doesn't change your recording settings.

## Troubleshooting

| Symptom | What to check |
|---|---|
| "Searching for iPhone" never ends | Same Wi‑Fi on both; Blackmagic Camera open on the camera screen; Remote Camera Control set to Remote Camera; HTTP server on; Local Network allowed for **both** apps (Mac: System Settings › Privacy & Security › Local Network). VPNs and guest networks often block devices from seeing each other. |
| Connects, but "Waiting for video" stays | A firewall on the Mac may be blocking the incoming stream (UDP port 9000). Allow bmonitor in System Settings › Network › Firewall. |
| "No camera" | Blackmagic Camera closed or the iPhone locked. Open it again; bmonitor reconnects by itself. |
| Video stutters | Weak Wi‑Fi. Move closer to the router or use 5 GHz. The "Packet loss" status in the top right shows lost packets. |

## Privacy

bmonitor collects nothing: no accounts, no analytics. It talks to the iPhone on your local network and, to check for updates, to GitHub. The script's speech recognition runs on the Mac.

## Build from source

```sh
brew install srt cmake
swift build -c release
swift test
scripts/build-app.sh --install --dmg   # bmonitor.app in /Applications and a .dmg in .build/dist
```

For development, the Swift package links Homebrew's libsrt. The packaging script instead builds libsrt and OpenSSL from source as universal libraries for macOS 14 and up (`scripts/build-deps.sh`), bundles them inside the app, builds the icon from the images in `scripts/icon/` (`scripts/make-icon.swift`), and signs ad hoc. `DESIGN.md` documents the interface. Code comments are in Portuguese.

## How it works

The Mac talks to Blackmagic Camera's REST and WebSocket API (port 4444) for status and controls. For video and audio, it points the camera's live stream (SRT, MPEG‑TS with HEVC and AAC) at itself, then demuxes and decodes every frame with VideoToolbox with no buffering queue. Glass to glass, that measures about 0.3 s, most of it on the iPhone side.

## Support

bmonitor is free and MIT-licensed. If it saved you a trip to the tripod, you can [buy me a coffee](https://www.buymeacoffee.com/dantearaujo).

## License

MIT, see [LICENSE](LICENSE). Bundled libraries and trademarks: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

bmonitor is an independent project, not affiliated with or endorsed by Blackmagic Design.

