# macOS STT/TTS Bridge 🎤🔊

> ⚠️ **Experimental & AI-Generated** — This project was developed with AI assistance and is in active development. Expect bugs!

Native macOS server application that makes Apple's high-quality Speech Recognition and Text-to-Speech engines accessible via HTTP/WebSocket API. Perfect for **Home Assistant** and other local automation systems.

## ✨ Features

- 🎯 **Native macOS Speech Recognition** — Apple's built-in Speech Framework, on-device.
- 🗣️ **High-Quality TTS** — AVSpeechSynthesizer voices, plus a synthetic "Siri" voice that routes through the `say` CLI.
- ⚡ **Streaming STT** — WebSocket-based real-time streaming with partial + final results.
- 🔒 **100 % Local & Private** — No cloud, all audio stays on your Mac.
- 🔐 **HTTPS + post-quantum TLS** — Optional TLS with PKCS#12 or PEM (incl. AES/3DES-encrypted keys); choose min/max version, cipher whitelist, and named curves including `x25519_MLKEM768`.
- 🌐 **Multi-bind** — Listen on multiple addresses at once (loopback, 0.0.0.0, or specific NICs).
- 🛡️ **Hardening** — Bearer auth (stored in Keychain), `--` end-of-options on subprocess args, 8 KiB cap on `text`, capped concurrent `say` subprocesses, and auth automatically required for any non-loopback bind.
- 🏠 **Home Assistant Integration** — Ready-made custom component.
- 🎨 **UI & Headless Modes** — Full Settings dialog (⌘,) for live reconfiguration, or run completely headless via launchd.
- 🌍 **Multi-Language** — Every locale Apple's Speech framework recognizes.

## 🚀 Quick Start

### Installation

1. **Download the app:**
   - Get the latest binary from the GitHub Releases page.
   - Move it to `/Applications`.
   - From `Terminal.app`, lift the quarantine flag:

     ```bash
     sudo xattr -r -d com.apple.quarantine /Applications/STTBridge.app
     ```

     *On Apple Silicon (M1+) unsigned binaries from the network are marked quarantined and the system will claim the app is "damaged." The command above removes that mark.*

2. **Run with UI:**
   - Double-click `STTBridge.app`.
   - Grant microphone permission when prompted.
   - Open **Settings… (⌘,)** to configure bind address, port, auth token, TLS, and language.

3. **Run headless (no window):**

   ```bash
   /Applications/STTBridge.app/Contents/MacOS/STTBridge --headless
   ```

### Install as Service (launchd)

```bash
cd /path/to/macos-stt-tts-bridge
./install-service.sh
```

The installer drops `io.github.daydy16.sttbridge.plist` into `~/Library/LaunchAgents/` and loads it. The agent runs as your user at login.

**Service commands:**

```bash
# Status
launchctl list | grep sttbridge

# Stop / Start
launchctl unload ~/Library/LaunchAgents/io.github.daydy16.sttbridge.plist
launchctl load   ~/Library/LaunchAgents/io.github.daydy16.sttbridge.plist

# Tail logs
tail -f /tmp/sttbridge.log
tail -f /tmp/sttbridge.error.log
```

## 📡 API Endpoints

The server speaks plain HTTP/1.1 (and HTTPS when TLS is enabled). All routes share the same port — default `8787`.

### Open endpoints (no auth)

| Method | Path | Returns |
|---|---|---|
| `GET` | `/healthz` | JSON `{ status, lang, onDeviceSTT }` |
| `GET` | `/languages` | `[String]` of `SFSpeechRecognizer.supportedLocales()` identifiers |
| `GET` | `/voices` | `[VoiceInfo]` including synthetic `Siri` voice |
| `GET` | `/` | HTML test UI |
| `GET` | `/app.js`, `/styles.css` | Assets for the test UI |

### Protected endpoints

Require an `Authorization: Bearer <token>` header when an auth token is configured, **always required** when bound to any non-loopback address.

**Speech-to-Text (POST):**

```bash
curl -X POST http://localhost:8787/stt \
  -H "Content-Type: audio/wav" \
  -H "X-Language: en-US" \
  -H "X-Sample-Rate: 16000" \
  -H "X-Channel-Count: 1" \
  --data-binary @audio.wav
```

Accepts `audio/wav` or `audio/l16` (raw PCM with `X-Sample-Rate` / `X-Channel-Count`). Query params: `lang`, `offline`.

**Text-to-Speech (GET or POST):**

```bash
# GET — query-string variant
curl "http://localhost:8787/tts?text=Hello%20World&voiceId=com.apple.voice.compact.en-US.Samantha" -o out.wav

# POST — JSON body
curl -X POST http://localhost:8787/tts \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello World","voiceId":"Siri","rate":1.0,"pitch":0.0}' -o out.wav
```

Optional query/body fields: `voiceId` (use `Siri` for the routed-through-`say` voice), `rate`, `pitch`, `speakLocal`. Returns `audio/wav` 16-bit PCM. Response includes `Content-Length` and `Content-Disposition: attachment; filename="…wav"`.

**`say` Endpoint (GET or POST):**

Direct access to the macOS `say` CLI — same input shapes as `/tts`, but always uses the system `say` binary with `--file-format=WAVE --data-format=LEI16@44100`.

```bash
curl "http://localhost:8787/say?text=Hello%20World" -o out.wav
```

Optional `speakLocal=true` plays through speakers and returns `{"ok":true}` instead of audio.

### WebSocket Streaming STT

For real-time speech recognition (partials + final transcript):

```javascript
const ws = new WebSocket('ws://localhost:8787/stt/stream?lang=en-US&partials=true&token=YOUR_TOKEN');

ws.binaryType = 'arraybuffer';
ws.onopen = () => {
  // Stream raw PCM audio chunks (16 kHz, mono, Int16)
  audioChunks.forEach(chunk => ws.send(chunk));
};

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  if (data.type === 'partial')  console.log('Partial:',  data.text);
  else if (data.type === 'final') console.log('Final:', data.text, data.confidence);
  else if (data.type === 'error') console.error(data.error);
};
```

Query params: `lang`, `offline`, `partials`, `token` (alternative to `Authorization` header).

## ⚙️ Settings & CLI

Most configuration lives in the **Settings dialog (⌘,)** with three tabs (**Server**, **Authentication**, **TLS**) and applies live — the server restarts on the spot when anything changes. Settings persist in `UserDefaults`; the auth token and TLS passphrase live in the macOS **Keychain**.

### CLI flags

Every persisted setting also has a CLI override (one-launch only — doesn't write back to disk):

```
--headless | --no-ui                Run without UI

--bind-host <addr[,addr,…]>         Bind to one or more IPs (default 127.0.0.1)
--port <n>                          HTTP/HTTPS port (default 8787)
--auth-token <token>                Bearer token for protected endpoints
--default-lang <locale>             Default STT/TTS locale (default en-US)
--offline-only <true|false>         Force on-device recognition

--tls <true|false>                  Enable HTTPS
--tls-cert-format <PKCS#12|PEM>     Certificate format on disk
--tls-password <pass>               Private-key passphrase
--tls-min-version <TLSv1.0…1.3>     Minimum TLS version
--tls-max-version <TLSv1.0…1.3>     Maximum TLS version
--tls-ciphers <a:b:c>               OpenSSL-style TLS 1.2 cipher whitelist
--tls-curves <a,b,c>                Allowed curves (e.g. x25519,x25519_MLKEM768)
--http-redirect-port <n>            Plain-HTTP listener that 308s to HTTPS

--import-pkcs12 <path|->            One-shot CLI cert import (use - for stdin)
--import-pem-cert <path|->          Import the PEM cert chain
--import-pem-key  <path|->          Import the PEM private key
```

### HTTPS quick recipe

```bash
# 1. Import the .p12 (sandbox blocks arbitrary paths — pipe via stdin)
cat new-bundle.p12 | STTBridge \
  --import-pkcs12 - \
  --tls-cert-format 'PKCS#12' \
  --tls-password "$PASS"

# 2. Launch HTTPS on 8888 with HTTP→HTTPS redirect on 8787
STTBridge --headless --port 8888 --tls true \
          --http-redirect-port 8787
```

## 🏠 Home Assistant Integration

### Installation

1. **HACS (recommended):**
   - Add `https://github.com/jshiflet/ha-local-macos-tts-stt` as a Custom Repository.
   - Install "STT/TTS Bridge".
   - Restart Home Assistant.

2. **Manual:**

   ```bash
   cd config/custom_components
   git clone https://github.com/jshiflet/ha-local-macos-tts-stt sttbridge
   ```

### Configuration

1. **Settings → Devices & Services → + Add Integration**.
2. Search for *STT/TTS Bridge*.
3. Enter host, port, and (if set) auth token.

### Use in Assist

**Settings → Voice Assistants → Assist** — select *STT/TTS Bridge STT* and *STT/TTS Bridge TTS*, then set the language.

## 🔧 Development

### Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- Swift 5.9+

### Build from Source

```bash
git clone https://github.com/jshiflet/macos-stt-tts-bridge.git
cd macos-stt-tts-bridge
open STTBridge.xcodeproj
# In Xcode, ⌘R to build & run.
```

### Project Structure

```
macos-stt-tts-bridge/
├── LICENSE                              # Project license (MIT)
├── README.md                            # This file
├── install-service.sh                   # LaunchAgent installer
├── io.github.daydy16.sttbridge.plist    # LaunchAgent template
└── STTBridge/
    ├── Config.xcconfig                  # Build-time config / versioning
    ├── build_pre_actions.sh             # Pre-build script (version baking)
    └── STTBridge/
        ├── STTBridgeApp.swift            # @main app + scenes (window, About, Settings)
        ├── ContentView.swift             # Main window UI (GroupBox sections, toolbar)
        ├── SettingsView.swift            # Settings dialog (Server / Auth / TLS tabs)
        ├── AboutView.swift               # About panel + Acknowledgements / license window
        ├── LICENSE.txt                   # MIT license bundled in the app for display
        ├── Persistence.swift             # Core Data stack (legacy)
        ├── Assets.xcassets               # Icon & UI assets
        ├── STTBridge.icon/               # New macOS icon composer assets
        ├── STTBridge_MVP.md              # Spec/notes (English)
        ├── STTBridge_MVP.de.md           # Spec/notes (German)
        ├── WebRoot/                      # Built-in HTML test client
        │   ├── index.html
        │   ├── app.js
        │   └── styles.css
        └── Server/
            ├── HTTPServer.swift           # SwiftNIO HTTP/HTTPS/WebSocket router
            ├── STTEngine.swift            # SFSpeechRecognizer wrapper
            ├── TTSEngine.swift            # AVSpeechSynthesizer + `say` integration
            ├── AudioResampler.swift       # Sample-rate / channel conversion
            ├── Models.swift               # Request / response DTOs
            ├── Config.swift               # Config loader (CLI > UserDefaults > env > defaults)
            ├── NetworkInterfaces.swift    # Local IPv4 enumeration for the bind picker
            ├── KeychainAuthToken.swift    # Keychain-backed token + TLS passphrase
            ├── TLSSupport.swift           # TLS versions, cipher / curve catalogs, cert store
            └── CLICertImporter.swift      # Headless cert-rotation CLI handler
```

## 🐛 Known Issues

- [ ] Performance with very long audio streams could be optimized.
- [ ] No batch processing endpoint.
- [ ] `say` voice quality varies by system locale download status.

## 🤝 Contributing

This project is experimental and was mostly AI-generated. Contributions are welcome!

1. Fork the repository.
2. Create a feature branch (`git checkout -b feature/amazing-feature`).
3. Commit your changes (`git commit -m 'Add amazing feature'`).
4. Push to the branch (`git push origin feature/amazing-feature`).
5. Open a Pull Request.

## 📝 License

MIT License — see [LICENSE](LICENSE). The same text ships inside the app and is reachable via **STTBridge → About STTBridge → Acknowledgements**.

## 🙏 Credits

- Developed with ❤️ and AI assistance.
- Uses Apple's Speech, AVFoundation, and Security frameworks.
- Networking via Apple's [SwiftNIO](https://github.com/apple/swift-nio) and [SwiftNIO SSL](https://github.com/apple/swift-nio-ssl).
- Inspired by Wyoming Protocol and Rhasspy.

## ⚠️ Disclaimer

This is an experimental project developed with AI assistance.
It is provided "as-is" without warranties. Use at your own risk!

---

**Like this project? Star it! ⭐**
