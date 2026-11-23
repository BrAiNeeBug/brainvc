# BrAiNVC `v4.0@16bit` · `v5.0@32bit (testing)`

**Optical data link** – turn any file into a stream of pixel frames, show it on a screen or put it into a video, and read it back from a screen, a video file or a camera.

[![Web v4.0](https://img.shields.io/badge/▶_Web_v4.0-stable-4cc2ff?style=for-the-badge)](https://braineebug.github.io/brainvc/brainvc.html)
[![Web v5.0](https://img.shields.io/badge/▶_Web_v5.0-testing-4cd98a?style=for-the-badge)](https://braineebug.github.io/brainvc/brainvc-v5.html)
[![Demo video](https://img.shields.io/badge/Demo-realtime_decoding_v2.3-ff6b6b?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/watch?v=UmDyXyGJnX0)
![Status](https://img.shields.io/badge/status-experimental-ffb454?style=for-the-badge)
![Use](https://img.shields.io/badge/use-private_%2F_non--commercial-lightgrey?style=for-the-badge)


> [!IMPORTANT]
> **Please use the web version.** v4.0 is the stable one, v5.0 is new and still being tested (see [Versions](#-versions)).
> BrAiNVC is **not safe** and still in **test mode** – please follow the [restrictions](#️-disclaimer--usage-restrictions) below. Really.

---

## ✨ What it does

- **Encode** a file into pixel frames (header, CRC16, Reed-Solomon error correction)
- **Show** the frames on a screen or **export** them as a video file
- **Scan** them back live from a screen, a video file or a camera
- **Same frame format** in the v4.0 web edition and in the AutoIt tool (v5.0 uses a new 32-bit header)

## 🆕 Versions

| Version | File | Frame counter | Max. file | Status |
|---|---|---|---|---|
| **v4.0** | [`brainvc.html`](https://braineebug.github.io/brainvc/brainvc.html) | 16 bit | 65 535 frames (about 50 MB, depending on grid and FEC) | stable |
| **v5.0** | [`brainvc-v5.html`](https://braineebug.github.io/brainvc/brainvc-v5.html) | **32 bit** | 4 GB (limited by RAM and the MP4 container) | **testing** |

v5.0 widens the frame header to `n(4) N(4) fileLen(4) crc(2)` (14 bytes instead of 10), which removes the 65 535-frame limit.
The scanner also checks that the file length fits the frame count, to reject rare false CRC hits.

> [!WARNING]
> **v5.0 is not compatible with v4.0.** Videos and frames from one version cannot be read by the other, and `brainvc.au3` / `brainvc.exe` still use the v4 format.
> Use the same version for sending and receiving. Feedback on v5.0 is welcome.

## 🚀 Quick start

1. Open the web version in your browser: **[v4.0 (stable)](https://braineebug.github.io/brainvc/brainvc.html)** or **[v5.0 (testing)](https://braineebug.github.io/brainvc/brainvc-v5.html)**.
2. **Send** tab: pick a file – the beacon (logo, then 3-2-1) runs first, so you have time to start the receiver and align it.
3. **Receive** tab: choose screen, video file or camera as source and let it decode.

## 🧩 Components

| Part | Purpose |
|---|---|
| `brainvc.html` | Web edition v4.0 – live scanner, encoder, video export. **Stable.** |
| `brainvc-v5.html` | Web edition v5.0 – same, with 32-bit frame counters. **Testing.** |
| `brainvc.au3` / `brainvc.exe` | Windows file tool for encoding/decoding with ffmpeg (v4 format) |
| `old/` | Older versions, including the **v2 runtime live-scanner** you can try out |

## 🎬 Demo

Latest realtime decoding test (v2.3): <https://www.youtube.com/watch?v=UmDyXyGJnX0>

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
