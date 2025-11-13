# Installation

## Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install -y ffmpeg parallel pv
chmod +x src/video_audio_validator.sh
```

## Fedora/RHEL
```bash
sudo dnf install -y ffmpeg parallel pv
chmod +x src/video_audio_validator.sh
```

## macOS
```bash
brew install ffmpeg parallel pv
chmod +x src/video_audio_validator.sh
```

## Verification
```bash
./src/video_audio_validator.sh --version
./src/video_audio_validator.sh --check-deps
```
