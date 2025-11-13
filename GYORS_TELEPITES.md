# Gyors Telepítés

## Ubuntu/Debian
```bash
sudo apt-get install -y ffmpeg
chmod +x src/video_audio_validator.sh
./src/video_audio_validator.sh --check-deps
```

## Fedora
```bash
sudo dnf install -y ffmpeg
chmod +x src/video_audio_validator.sh
```

## macOS
```bash
brew install ffmpeg
chmod +x src/video_audio_validator.sh
```

## Használat
```bash
./src/video_audio_validator.sh -d /media -P
./src/video_audio_validator.sh -d /media -R -B -P
```
