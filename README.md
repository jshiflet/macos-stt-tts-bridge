# macOS STT/TTS Bridge 🎤🔊

> ⚠️ **Experimental & AI-Generated** - This project was developed with AI assistance and is in active development. Expect bugs!

Native macOS server application that makes Apple's high-quality Speech Recognition and Text-to-Speech engines accessible via HTTP/WebSocket API. Perfect for **Home Assistant** and other local automation systems.

## ✨ Features

- 🎯 **Native macOS Speech Recognition** - Uses Apple's built-in Speech Framework
- 🗣️ **High-Quality TTS** - Natural-sounding speech output in many languages
- ⚡ **Streaming STT** - WebSocket-based real-time streaming for minimal latency
- 🔒 **100% Local & Private** - No cloud, all data stays on your Mac
- 🏠 **Home Assistant Integration** - Ready-made custom component available
- 🎨 **UI & Headless Modes** - Run with or without graphical interface
- 🌍 **Multi-Language** - Supports all languages supported by macOS

## 🚀 Quick Start

### Installation

1. **Download the app:**
    - Download the latest version from Releases
    - Extract and move to /Applications
    - From Terminal.app, run `sudo xattr -r -d com.apple.quarantine /Applications/STTBridge.app`\
    *__Note:__ When running on Apple Silicon (A18, M1, M2, M3, M4, M5, etc.) the application will be marked as quarantined and will result in an error message about the application being corrupted when you try to launch it. This command resolves that problem.*

2. **Start with UI:**
   - Double-click on `STTBridge.app`
   - Allow microphone access when prompted

3. **Start headless (without UI):**

   ```bash
   /Applications/STTBridge.app/Contents/MacOS/STTBridge --headless
   ```

### Install as Service

Automatic startup on login:

```bash
# Change to project directory
cd /path/to/STTBridge

# Install service
./install-service.sh
```

**Service commands:**

```bash
# Check status
launchctl list | grep sttbridge

# Stop
launchctl unload ~/Library/LaunchAgents/io.github.jshiflet.sttbridge.plist

# Start
launchctl load ~/Library/LaunchAgents/io.github.jshiflet.sttbridge.plist

# View logs
tail -f /tmp/sttbridge.log
```

## 📡 API Endpoints

### HTTP Endpoints

**Speech-to-Text (HTTP POST):**

```bash
curl -X POST http://localhost:8787/stt \
  -H "Content-Type: audio/wav" \
  -H "X-Language: en-US" \
  -H "X-Sample-Rate: 16000" \
  -H "X-Channel-Count: 1" \
  --data-binary @audio.wav
```

**Text-to-Speech:**

```bash
curl "http://localhost:8787/tts?text=Hello%20World&lang=en-US" -o output.wav
```

**Available voices:**

```bash
curl http://localhost:8787/voices
```

### WebSocket Streaming STT

For real-time speech recognition:

```javascript
const ws = new WebSocket('ws://localhost:8787/stt/stream?lang=en-US');

ws.onopen = () => {
  // Start message
  ws.send(JSON.stringify({
    type: 'start',
    sampleRate: 16000,
    channels: 1,
    language: 'en-US'
  }));
  
  // Stream audio chunks
  audioChunks.forEach(chunk => ws.send(chunk));
  
  // End stream
  ws.send(JSON.stringify({ type: 'end' }));
};

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  if (data.type === 'partial') {
    console.log('Partial:', data.text);
  } else if (data.type === 'final') {
    console.log('Final:', data.text);
  }
};
```

## 🏠 Home Assistant Integration

### Installation

1. **HACS Installation (recommended):**
   - Add `https://github.com/jshiflet/ha-local-macos-tts-stt` as Custom Repository
   - Install "STT/TTS Bridge"
   - Restart Home Assistant

2. **Manual Installation:**

   ```bash
   cd config/custom_components
   git clone https://github.com/jshiflet/ha-local-macos-tts-stt sttbridge
   ```

### Configuration

1. Go to **Settings → Devices & Services**
2. Click **+ Add Integration**
3. Search for "STT/TTS Bridge"
4. Enter host and port (default: `localhost:8787`)

### Usage in Assist Pipeline

1. **Settings → Voice Assistants → Assist**
2. Select for Speech-to-Text: `STT/TTS Bridge STT`
3. Select for Text-to-Speech: `STT/TTS Bridge TTS`
4. Language: `en-US` or your desired language

## ⚙️ Configuration

The app uses default settings that work for most applications:

- **Host:** `127.0.0.1` (localhost)
- **Port:** `8787`
- **Auth Token:** Optional (can be set in Config.swift)
- **Default Language:** `en-US`

To customize, edit `STTBridge/Server/Config.swift` and recompile.

## 🔧 Development

### Requirements

- macOS 13.0+
- Xcode 15.0+
- Swift 5.9+

### Build from Source

```bash
# Clone repository
git clone https://github.com/jshiflet/macos-stt-tts-bridge.git
cd macos-stt-tts-bridge

# Open in Xcode
open STTBridge.xcodeproj

# Build & Run in Xcode (Cmd+R)
```

### Project Structure

```
STTBridge/
├── STTBridgeApp.swift      # Main App & UI Toggle
├── ContentView.swift        # SwiftUI Interface
├── Server/
│   ├── HTTPServer.swift     # HTTP/WebSocket Server
│   ├── STTEngine.swift      # Speech Recognition
│   ├── TTSEngine.swift      # Text-to-Speech
│   ├── Config.swift         # Configuration
│   └── Models.swift         # Data Models
└── Webroot/                 # Test Web UI
    ├── index.html
    ├── app.js
    └── styles.css
```

## 🐛 Known Issues

- [ ] Performance with very long audio streams could be optimized
- [ ] No support for batch processing
- [ ] Auth token implementation is basic

## 🤝 Contributing

This project is experimental and was mostly AI-generated. Contributions are welcome!

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📝 License

MIT License - see [LICENSE](LICENSE) file

## 🙏 Credits

- Developed with ❤️ and AI assistance
- Uses Apple's Speech Framework and AVFoundation
- Inspired by Wyoming Protocol and Rhasspy

## ⚠️ Disclaimer

This is an experimental project developed with AI assistance.
It is provided "as-is" without warranties. Use at your own risk!

---

**Like this project? Star it! ⭐**
