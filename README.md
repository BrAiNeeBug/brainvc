# BrAiNVC `v5.4`

**Optical + acoustic data link** – turn any file into a stream of pixel frames (or sound), show it on a screen, put it into a video or an audio file, and read it back from a screen, a video file, a camera or an audio file.

[![Web v5.4](https://img.shields.io/badge/▶_Web_v5.4-stable-4cd98a?style=for-the-badge)](https://braineebug.github.io/brainvc/brainvc.html)
![Status](https://img.shields.io/badge/status-experimental-ffb454?style=for-the-badge)
![Use](https://img.shields.io/badge/use-private_%2F_non--commercial-lightgrey?style=for-the-badge)


> [!IMPORTANT]
> **Please use the web version v5.4.** Older versions (v4.0, v2) are kept in the `old/` folder to read old videos (see [Versions](#-versions)).
> BrAiNVC is **not safe** and still in **test mode** – please follow the [restrictions](#️-disclaimer--usage-restrictions) below. Really.

---

## ✨ What it does
[`TEST-VIDEO`](https://www.youtube.com/watch?v=AmDRbs97zhk)
- **Encode** a file into pixel frames (header, CRC16, Reed-Solomon error correction)
- **Show** the frames on a screen or **export** them as a video file
- **Scan** them back live from a screen, a video file or a camera
- **A-Link** – the same frames as sound: create **WAV, MP3 or WebM/Opus** files and read them back
- **Small videos** – the Auto bitrate adapts to the data rate, so video files stay small
- **Big files** – 32-bit frame counters, no more 65 535-frame limit


## 🚀 Quick start

1. Open **[BrAiNVC](https://braineebug.github.io/brainvc/brainvc.html)** in your browser.
2. **Send** tab: pick a file and choose **Screen** or **Video file**. With Screen, the beacon (logo, then 3-2-1) runs first, so you have time to start the receiver and align it.
3. **Receive** tab: choose screen, video file or camera as source and let it decode.
4. **A-Link** tab (optional): pick a file, a profile and a format, press *Create audio*, and later load the audio file in the *Receive* box of the same tab.


## 🔊 A-Link (acoustic data link)

A-Link uses the same frames, CRC16 and Reed-Solomon recovery as the optical link, but sends them as 2-FSK or 4-FSK tones.

- **Formats:** WAV (lossless), MP3 and WebM/Opus, for creating and for reading. MP3 encoding loads the *lamejs* library from a CDN once, so it needs an internet connection the first time.
- **Self-describing:** a fixed 1200 baud preamble (sync word plus all settings) leads into the data, so the receiver finds the start and the settings on its own, even when a codec delays the signal. You only set values on the sending side.
- **Settings:** baud, lowest tone, tone spacing, 2 or 4 tones, level, sample rate, codec bitrate and profiles. Frame size, K and M come from the shared **Format** panel.
- **Verify after creating:** finished MP3 and WebM files are decoded again at once, so you see immediately whether the settings survive the codec.


## 🧩 Components

| Part | Purpose |
|---|---|
| `brainvc.html` | Web edition v5.4 – live scanner, encoder, video export, A-Link audio. |
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
