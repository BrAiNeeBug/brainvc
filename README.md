# BrAiNVC `v5.2`

**Optical + acoustic data link** – turn any file into a stream of pixel frames (or sound), show it on a screen, put it into a video or an audio file, and read it back from a screen, a video file, a camera or an audio file.

[![Web v5.2](https://img.shields.io/badge/▶_Web_v5.2-stable-4cd98a?style=for-the-badge)](https://braineebug.github.io/brainvc/brainvc.html)
![Status](https://img.shields.io/badge/status-experimental-ffb454?style=for-the-badge)
![Use](https://img.shields.io/badge/use-private_%2F_non--commercial-lightgrey?style=for-the-badge)


> [!IMPORTANT]
> **Please use the web version v5.2.** Older versions (v4.0, v2) are kept in the `old/` folder to read old videos (see [Versions](#-versions)).
> BrAiNVC is **not safe** and still in **test mode** – please follow the [restrictions](#️-disclaimer--usage-restrictions) below. Really.

---

## ✨ What it does
[`TEST-VIDEO`](https://www.youtube.com/watch?v=AmDRbs97zhk)
- **Encode** a file into pixel frames (header, CRC16, Reed-Solomon error correction)
- **Show** the frames on a screen or **export** them as a video file
- **Scan** them back live from a screen, a video file or a camera
- **A-Link** – the same frames as sound: create **WAV, MP3 or WebM/Opus** files and read them back (experimental, see [A-Link](#-a-link-acoustic-data-link))
- **Small videos** – the Auto bitrate adapts to the data rate, so video files stay small
- **Big files** – 32-bit frame counters, no more 65 535-frame limit

## 🆕 Versions

| Version | File | Frame counter | Max. file | Status |
|---|---|---|---|---|
| **v5.2** | [`brainvc.html`](https://braineebug.github.io/brainvc/brainvc.html) | **32 bit** | 4 GB (limited by RAM and the MP4 container) | **stable, recommended** |
| v5.1 | – | 32 bit | 4 GB | previous (same optical format, no A-Link) |
| v4.0 | `old/` | 16 bit | 65 535 frames (about 50 MB, depending on grid and FEC) | legacy |

**What is new in v5.2:**
- **A-Link tab** (experimental): sends a file as FSK tones in a WAV, MP3 or WebM/Opus file and decodes it again. It has its own settings panel with profiles, and the receiver reads all settings from the audio file itself. Details [below](#-a-link-acoustic-data-link).
- **Cleaner Send tab:** pick the file, choose **Screen** or **Video file**, and set speed and beacon once. Video-only options (frame rate, repeats, quality) appear only in video mode.
- Clearer labels: *Speed (frames/s)*, *Data per group (K)* and *Parity per group (M)* instead of several different "data frames" fields.

**What was new in v5:**
- The frame header is now `n(4) N(4) fileLen(4) crc(2)` (14 bytes instead of 10), which removes the 65 535-frame limit.
- The scanner checks that the file length fits the frame count, to reject rare false CRC hits.
- Video export has an **Auto (small file)** bitrate (default) that follows the data rate, plus Tiny (2) and Small (4 Mbit/s) presets and variable bitrate mode. Files are smaller than with v4.0 and smaller than the old ffmpeg tool.

> [!WARNING]
> **v5 is not compatible with v4.0.** Videos and frames from one version cannot be read by the other, and the old `brainvc.au3` / `brainvc.exe` tool also used the v4 format.
> Use the same version for sending and receiving.

## 🚀 Quick start

1. Open **[BrAiNVC v5.2](https://braineebug.github.io/brainvc/brainvc.html)** in your browser.
2. **Send** tab: pick a file and choose **Screen** or **Video file**. With Screen, the beacon (logo, then 3-2-1) runs first, so you have time to start the receiver and align it.
3. **Receive** tab: choose screen, video file or camera as source and let it decode.
4. **A-Link** tab (optional): pick a file, a profile and a format, press *Create audio*, and later load the audio file in the *Receive* box of the same tab.

## 🔊 A-Link (acoustic data link)

A-Link uses the same frames, CRC16 and Reed-Solomon recovery as the optical link, but sends them as 2-FSK or 4-FSK tones.

- **Formats:** WAV (lossless), MP3 and WebM/Opus, for creating and for reading. MP3 encoding loads the *lamejs* library from a CDN once, so it needs an internet connection the first time.
- **Self-describing:** a fixed 1200 baud preamble (sync word plus all settings) leads into the data, so the receiver finds the start and the settings on its own, even when a codec delays the signal. You only set values on the sending side.
- **Settings:** baud, lowest tone, tone spacing, 2 or 4 tones, level, sample rate, codec bitrate, frame size, K and M, plus profiles.
- **Verify after creating:** finished MP3 and WebM files are decoded again at once, so you see immediately whether the settings survive the codec.

Profiles (tested with real libopus and LAME encoders in a Node test harness):

| Profile | Settings | Net data rate |
|---|---|---|
| WAV max | 57.6 kHz, 19200 baud | about 14 kbit/s |
| MP3 fast | 4800 baud, 128 kbit/s | about 3.7 kbit/s |
| MP3 small | 2400 baud, 80 kbit/s | about 1.8 kbit/s |
| WebM/Opus | 1200 baud, 48 kbit/s | about 0.9 kbit/s |
| Robust | 600 baud, works down to Opus 32 kbit/s | about 0.46 kbit/s |

Lossy codecs lose high tones: Opus below 64 kbit/s keeps only about 3 kHz, MP3 needs about 96 kbit/s for 4800 baud. Audio files are much larger than the payload, because the codec spends its bitrate on the tones. WebM/Opus is recorded in real time by the browser (it takes as long as the playing time); WAV and MP3 are created faster than real time.

## 🧩 Components

| Part | Purpose |
|---|---|
| `brainvc.html` | Web edition v5.2 – live scanner, encoder, video export, A-Link audio. |
| `old/` | Older versions: **v4.0** (16-bit frame counter) and **v2** (including the runtime live-scanner you can try out) |

---

## ⚠️ Disclaimer & Usage Restrictions

**BrAiNVC is intended strictly for private, personal and non-commercial use.**

Use by companies, commercial organizations, military organizations, government agencies, public authorities or other institutional entities is **not permitted without prior explicit written permission from the project author.**
Such organizations must contact the author and obtain approval before using, deploying, integrating or distributing BrAiNVC.

### 🔒 Security Notice

BrAiNVC is an experimental project, provided **AS IS**, without any guarantee of security, reliability, availability or data integrity.
It has not been designed, audited or certified for professional, commercial, military, governmental or security-critical environments.

- No guarantee of confidentiality or secure data transmission.
- No protection against interception, manipulation or unauthorized access.
- Must **not** be used to transmit sensitive, confidential, classified or otherwise critical information.
- Must **not** be considered a secure communication system.

### 📄 No Warranty / Limitation of Liability

The software is provided without any express or implied warranty. The author accepts no responsibility for damages, data loss, security incidents or other consequences resulting from use or misuse of this project, to the extent permitted by applicable law.

**By using BrAiNVC, you acknowledge and accept these limitations and usage restrictions.**

If you represent a company, military organization, government agency or other institution and wish to use BrAiNVC, please contact the project author for prior authorization.
