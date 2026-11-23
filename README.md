# BrAiNVC `v4.0`

**Optical data link** – turn any file into a stream of pixel frames, show it on a screen or put it into a video, and read it back from a screen, a video file or a camera.

[![Web version](https://img.shields.io/badge/▶_Web_version-open-4cc2ff?style=for-the-badge)](https://braineebug.github.io/brainvc/brainvc.html)
[![Demo video](https://img.shields.io/badge/Demo-realtime_decoding_v2.3-ff6b6b?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/watch?v=UmDyXyGJnX0)
![Status](https://img.shields.io/badge/status-experimental-ffb454?style=for-the-badge)
![Use](https://img.shields.io/badge/use-private_%2F_non--commercial-lightgrey?style=for-the-badge)

<p align="center">
  <img width="815" alt="BrAiNVC web – send" src="https://github.com/user-attachments/assets/fb8cce57-5526-4d43-bf21-83102277d831" />
</p>
<p align="center">
  <img width="582" alt="BrAiNVC web – receive" src="https://github.com/user-attachments/assets/95c202e7-46db-494d-b9e9-7a9ec8a8671a" />
</p>

> [!IMPORTANT]
> **Please use the web version.** The Windows runtime (`brainvc.au3` / `brainvc.exe`) is only meant for testing and very large files.
> BrAiNVC is **not safe** and still in **test mode** – please follow the [restrictions](#️-disclaimer--usage-restrictions) below. Really.

---

## ✨ What it does

- **Encode** a file into pixel frames (header, CRC16, Reed-Solomon error correction)
- **Show** the frames on a screen or **export** them as a video file
- **Scan** them back live from a screen, a video file or a camera
- **Same frame format** in the web edition and in the AutoIt tool

## 🚀 Quick start

1. Open the **[web version](https://braineebug.github.io/brainvc/brainvc.html)** in your browser.
2. **Send** tab: pick a file – the beacon (logo, then 3-2-1) runs first, so you have time to start the receiver and align it.
3. **Receive** tab: choose screen, video file or camera as source and let it decode.

## 🧩 Components

| Part | Purpose |
|---|---|
| `brainvc.html` | Web edition – live scanner, encoder, video export. **Recommended.** |
| `brainvc.au3` / `brainvc.exe` | Windows file tool (uses ffmpeg) – for testing and very large files |
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
