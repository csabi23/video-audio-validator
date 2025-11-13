# 🎬 Média Validátor v5.1

Professzionális FFmpeg alapú videó/audio validátor és javító.

## Gyors Kezdés

```bash
sudo apt-get install ffmpeg
chmod +x src/video_audio_validator.sh
./src/video_audio_validator.sh --check-deps
```

## Függőségek
- bash 4.0+
- ffmpeg (libx264/libx265)
- parallel (opcionális)

## Használat

```bash
# Ellenőrzés
./src/video_audio_validator.sh -d /media -P

# Javítás
./src/video_audio_validator.sh -d /media -R -B -P
```
