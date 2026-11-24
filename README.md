# BrAiNVC `v5.1`

**Optical data link** – turn any file into a stream of pixel frames, show it on a screen or put it into a video, and read it back from a screen, a video file or a camera.

[![Web v5.1](https://img.shields.io/badge/▶_Web_v5.1-stable-4cd98a?style=for-the-badge)](https://braineebug.github.io/brainvc/brainvc.html)
![Status](https://img.shields.io/badge/status-experimental-ffb454?style=for-the-badge)
![Use](https://img.shields.io/badge/use-private_%2F_non--commercial-lightgrey?style=for-the-badge)


> [!IMPORTANT]
> **Please use the web version v5.1.** v4.0 is only kept to read old videos (see [Versions](#-versions)).
> BrAiNVC is **not safe** and still in **test mode** – please follow the [restrictions](#️-disclaimer--usage-restrictions) below. Really.

---

## ✨ What it does

- **Encode** a file into pixel frames (header, CRC16, Reed-Solomon error correction)
- **Show** the frames on a screen or **export** them as a video file
- **Scan** them back live from a screen, a video file or a camera
- **Small videos** – the Auto bitrate adapts to the data rate, so video files stay small
- **Big files** – 32-bit frame counters, no more 65 535-frame limit

## 🆕 Versions

| Version | File | Frame counter | Max. file | Status |
|---|---|---|---|---|
| **v5.1** | [`brainvc.html`](https://braineebug.github.io/brainvc/brainvc.html) | **32 bit** | 4 GB (limited by RAM and the MP4 container) | **stable, recommended** |

**What is new in v5:**
- The frame header is now `n(4) N(4) fileLen(4) crc(2)` (14 bytes instead of 10), which removes the 65 535-frame limit.
- The scanner checks that the file length fits the frame count, to reject rare false CRC hits.
- Video export has an **Auto (small file)** bitrate (default) that follows the data rate, plus Tiny (2) and Small (4 Mbit/s) presets and variable bitrate mode. Files are smaller than with v4.0 and smaller than the old ffmpeg tool.

> [!WARNING]
> **v5 is not compatible with v4.0.** Videos and frames from one version cannot be read by the other, and `brainvc.au3` / `brainvc.exe` use the v4 format.
> Use the same version for sending and receiving.

## 🚀 Quick start

1. Open **[BrAiNVC v5.1](https://braineebug.github.io/brainvc/brainvc.html)** in your browser.
2. **Send** tab: pick a file – the beacon (logo, then 3-2-1) runs first, so you have time to start the receiver and align it.
3. **Receive** tab: choose screen, video file or camera as source and let it decode.

## 🧩 Components

| Part | Purpose |
|---|---|
| `brainvc.html` | Web edition v5.1 – live scanner, encoder, video export. |
| `old/` | Older versions, including the **v2 runtime live-scanner** you can try out |

## 🎬 Demo



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
