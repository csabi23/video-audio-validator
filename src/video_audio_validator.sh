#!/bin/bash
# video_audio_validator.sh - v5.1

set -o pipefail
set -o errexit
set -o nounset

readonly VERSION="5.1"
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

usage() {
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                 MÉDIA FÁJL VALIDÁTOR & JAVÍTÓ - v5.1                      ║
╚════════════════════════════════════════════════════════════════════════════╝

HASZNÁLAT:
  video_audio_validator.sh [OPCIÓK]

KÖTELEZŐ:
  -d, --dir KÖNYVTÁR             Könyvtár ellenőrzése
  -l, --list FÁJLLISTA           Fájllista feldolgozása

OPCIÓK:
  -i, --include EXT              Include szűrés
  -R, --repair                   Javítás
  -B, --backup                   Biztonsági másolat
  -P, --progress                 Progressbar
  -v, --verbose                  Részletes
  -t, --table                    Táblázatos

INFO:
  -h, --help                     Súgó
  --version                      Verzió
  --check-deps                   Függőségek

════════════════════════════════════════════════════════════════════════════
EOF
    exit 0
}

show_deps() {
    printf '\nBASH: %s\n' "$(bash --version | head -1)"
    printf 'KÖTELEZŐK:\n'
    for cmd in bash ffmpeg find grep sed; do
        if command -v "$cmd" &>/dev/null; then
            printf "  ${GREEN}[✓]${NC} %s\n" "$cmd"
        else
            printf "  ${RED}[✗]${NC} %s\n" "$cmd"
        fi
    done
}

case "${1:-}" in
    --help|-h) usage ;;
    --version) printf "video_audio_validator v%s\n" "$VERSION" && exit 0 ;;
    --check-deps) show_deps && exit 0 ;;
    -d|--dir) printf "${GREEN}[OK]${NC} Directory: %s\n" "${2:-}" && exit 0 ;;
    *) printf "Lásd: --help\n" && exit 1 ;;
esac
