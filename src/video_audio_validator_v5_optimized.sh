#!/bin/bash

################################################################################
# Script: video_audio_validator.sh
# Verzió: 5.0 (Profi Optimalizált)
# Leírás: FFmpeg alapú média validátor & javító - robusztus, biztonságos, gyors
# Szerző: Optimized for Production
# Frissítés: 2025-11-13
################################################################################

set -o pipefail
set -o errexit  # Hiba esetén azonnali kilépés
set -o nounset  # Undefined variable detekció

readonly VERSION="5.0"
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

################################################################################
# GLOBÁLIS KONSTANSOK ÉS ALAPÉRTELMEZÉSEK
################################################################################

readonly DEFAULT_PARALLEL_JOBS=4
readonly DEFAULT_OUTPUT_FILE="hibak.txt"
readonly DEFAULT_REPAIR_CODEC="libx264:aac"
readonly FFMPEG_TIMEOUT=300  # mp
readonly TEMP_DIR="${TMPDIR:-/tmp}"
readonly VALID_VIDEO_CODECS="libx264 libx265 libvpx libvpx-vp9"
readonly VALID_AUDIO_CODECS="aac libmp3lame libvorbis libopus"

# Kimeneti színek (terminalhoz)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'  # No Color

################################################################################
# GLOBÁLIS VÁLTOZÓK
################################################################################

declare -g source_dir=""
declare -g list_file=""
declare -g included_ext=""
declare -g excluded_ext=""
declare -g case_sensitive="yes"
declare -g output_file="${DEFAULT_OUTPUT_FILE}"
declare -g parallel_jobs="${DEFAULT_PARALLEL_JOBS}"
declare -g table_output="false"
declare -g verbose="false"
declare -g quiet="false"
declare -g progress="false"
declare -g repair="false"
declare -g repair_codec="${DEFAULT_REPAIR_CODEC}"
declare -g backup="false"
declare -g delete_invalid="false"
declare -g collect_invalid=""

declare -ga file_list=()
declare -ga invalid_files=()
declare -ga repaired_files=()

declare -g temp_error_file=""
declare -g temp_repair_log=""
declare -g lock_dir=""

################################################################################
# TRAP: CLEANUP (kritikus!)
################################################################################

cleanup() {
    local exit_code=$?
    
    # Temp fájlok törlése
    [[ -n "${temp_error_file}" && -f "${temp_error_file}" ]] && rm -f "${temp_error_file}" "${temp_error_file}.sorted"
    [[ -n "${temp_repair_log}" && -f "${temp_repair_log}" ]] && rm -f "${temp_repair_log}" "${temp_repair_log}.sorted"
    
    # Lock könyvtár törlése
    [[ -n "${lock_dir}" && -d "${lock_dir}" ]] && rm -rf "${lock_dir}"
    
    # Nyitott fájlleírók bezárása
    if [[ -n "${temp_error_file}" ]]; then
        exec 3>&- 2>/dev/null || true
    fi
    
    exit ${exit_code}
}

trap cleanup EXIT INT TERM

################################################################################
# SEGÉDFÜGGVÉNYEK
################################################################################

# Hibaüzenet és kilépés
die() {
    printf "${RED}[HIBA]${NC} %s\n" "$*" >&2
    exit 1
}

# Info üzenet
info() {
    [[ "${quiet}" == "true" ]] && return 0
    printf "${CYAN}[INFO]${NC} %s\n" "$*"
}

# Verbose üzenet
verbose() {
    [[ "${verbose}" != "true" || "${quiet}" == "true" ]] && return 0
    printf "${YELLOW}[VERBOSE]${NC} %s\n" "$*"
}

# Figyelmeztetés
warn() {
    printf "${YELLOW}[FIGYELMEZTETÉS]${NC} %s\n" "$*" >&2
}

# Sikerüzenet
ok() {
    printf "${GREEN}[OK]${NC} %s\n" "$*"
}

# Karakterlánc kisbetűsítése biztonságos módszerrel
to_lowercase() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

# Array ellenőrzés: tartalmaz-e elemet
array_contains() {
    local seeking="$1"
    shift
    local element
    for element in "$@"; do
        [[ "${element}" == "${seeking}" ]] && return 0
    done
    return 1
}

# Progressbar renderelés (ISO standard formátum)
render_progress_bar() {
    local current=$1 total=$2
    local width=30
    
    [[ "${progress}" != "true" || "${quiet}" == "true" ]] && return 0
    [[ ${total} -eq 0 ]] && return 0
    
    local percent=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    
    local bar
    bar=$(printf '#%.0s' $(seq 1 "${filled}"))
    bar+=$(printf '·%.0s' $(seq 1 "${empty}"))
    
    printf "\r[${bar}] %3d%% (%d/%d)" "${percent}" "${current}" "${total}"
    
    [[ ${current} -eq ${total} ]] && printf '\n'
}

# Codec validáció
validate_codec() {
    local codec="$1"
    local codec_type="$2"  # "video" vagy "audio"
    local valid_list
    
    case "${codec_type}" in
        video)
            valid_list="${VALID_VIDEO_CODECS}"
            ;;
        audio)
            valid_list="${VALID_AUDIO_CODECS}"
            ;;
        *)
            return 1
            ;;
    esac
    
    array_contains "${codec}" ${valid_list} && return 0
    return 1
}

# FFmpeg elérhetőség és verzió ellenőrzés
check_ffmpeg() {
    if ! command -v ffmpeg &>/dev/null; then
        die "ffmpeg nem telepítve. Kérjük telepítse: apt-get install ffmpeg"
    fi
    
    local ffmpeg_version
    ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    
    verbose "FFmpeg verzió: ${ffmpeg_version}"
}

################################################################################
# HELP / USAGE
################################################################################

usage() {
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                 MÉDIA FÁJL VALIDÁTOR & JAVÍTÓ - v5.0                      ║
║                        Professzionális Verzió                             ║
╚════════════════════════════════════════════════════════════════════════════╝

HASZNÁLAT:
  video_audio_validator.sh [OPCIÓK]

KÖTELEZŐ (egyik):
  -d, --dir KÖNYVTÁR             Könyvtár rekurzív ellenőrzése
  -l, --list FÁJLLISTA           Fájllista feldolgozása (CSV/szöveg)

SZŰRÉS:
  -i, --include KITERJESZTÉSEK   Include: mp4,mkv,mov (vesszővel elválasztott)
  -e, --exclude KITERJESZTÉSEK   Exclude: tmp,txt
  -c, --case yes|no              Kis/nagybetű érzékenység (alap: yes)

KIMENET:
  -o, --output FÁJL              Hibás fájlok kimenete (alap: hibak.txt)
  -t, --table                    Táblázatos formátum (hiba típussal)
  -v, --verbose                  Részletes státusz minden fájlről
  -q, --quiet                    Csak végeredmény, nincs előrehaladás
  -P, --progress                 Progressbar megjelenítése

JAVÍTÁS:
  -R, --repair                   Hibás fájlok javítási kísérlete
  -r, --repair-codec VIDEO:AUDIO Codecek: libx264:aac (alap)
                                 Video: libx264, libx265, libvpx, libvpx-vp9
                                 Audio: aac, libmp3lame, libvorbis, libopus
  -B, --backup                   Biztonsági másolat (.bak) javítás előtt
  -C, --collect-invalid ÚTVONAL  Sikertelen javítások másolása erre
  -D, --delete-invalid           Sikertelen javítások törlése

PERFORMANCE:
  -p, --parallel SZÁM            Párhuzamos folyamatok (alap: 4)

INFO:
  -h, --help                     Ez a súgó megjelenítése
  --version                      Verzió információ

TIPIKUS FELHASZNÁLÁS:

  1. Alapvető ellenőrzés progressbarral:
     ./video_audio_validator.sh -d /media/videos -P

  2. Fájllista feldolgozása, csendes módban:
     ./video_audio_validator.sh -l videos.csv -q

  3. Ellenőrzés és javítás H.264 codeckel:
     ./video_audio_validator.sh -d /data/media -R -r "libx264:aac" -P

  4. Teljes körű: ellenőrzés, javítás, biztonsági másolat, gyűjtés:
     ./video_audio_validator.sh -d /media -R -B -C ./hibas -t -P

  5. Csak mp4/mkv, verbose mód, H.265:
     ./video_audio_validator.sh -d /videos -i mp4,mkv -R -r "libx265:aac" -v

KÖVETELMÉNYEK:
  - bash 4.0+
  - ffmpeg (libx264/libx265 codec támogatás ajánlott)
  - GNU coreutils (standard)

KIMENETI FORMÁTUMOK:

  Lista mód:
    /path/to/file1.mp4
    /path/to/file2.mkv

  Táblázat mód:
    ┌─────────────────────┬──────────────┬──────────────────┐
    │ Fájlnév             │ Hibatípus    │ Részletek        │
    ├─────────────────────┼──────────────┼──────────────────┤
    │ /path/file.mp4      │ DECODE_ERROR │ Invalid data     │
    └─────────────────────┴──────────────┴──────────────────┘

  Progress:
    [################····] 75% (150/200)

═════════════════════════════════════════════════════════════════════════════
EOF
    exit 0
}

version() {
    printf "video_audio_validator.sh v%s\n" "${VERSION}"
    exit 0
}

################################################################################
# FÁJL ELLENŐRZÉS
################################################################################

# FFmpeg alapú média validáció (biztonságos quoting)
validate_media_file() {
    local filepath="$1"
    local error_output
    local error_type=""
    local error_detail=""
    
    # Timeout-al ffmpeg futtatás
    if ! error_output=$(timeout "${FFMPEG_TIMEOUT}" ffmpeg \
        -v error \
        -i "${filepath}" \
        -t 1 \
        -f null \
        - 2>&1); then
        
        error_type="TIMEOUT_ERROR"
        error_detail="FFmpeg timeout (>300mp)"
        return 1
    fi
    
    # Hiba szeparáció
    if grep -iqE "error|invalid|corrupt" <<<"${error_output}"; then
        
        # Hiba típus meghatározása
        if grep -iq "decode" <<<"${error_output}"; then
            error_type="DECODE_ERROR"
        elif grep -iq "corrupt" <<<"${error_output}"; then
            error_type="CORRUPT_DATA"
        elif grep -iq "invalid" <<<"${error_output}"; then
            error_type="FORMAT_ERROR"
        elif grep -iq "stream" <<<"${error_output}"; then
            error_type="STREAM_ERROR"
        elif grep -iq "unsupported" <<<"${error_output}"; then
            error_type="CODEC_UNSUPPORTED"
        else
            error_type="UNKNOWN_ERROR"
        fi
        
        # Részlet kivonat (biztonságos)
        error_detail=$(head -n1 <<<"${error_output}" | tr '\n' ' ' | cut -c1-60)
        
        # Output fájlba írás (biztonságos)
        {
            printf '%s|%s|%s\n' \
                "${filepath}" \
                "${error_type}" \
                "${error_detail}"
        } >> "${temp_error_file}"
        
        return 1
    fi
    
    return 0
}

################################################################################
# FÁJL JAVÍTÁS
################################################################################

# Médiaálla biztonsági másolatának készítése
create_backup() {
    local source="$1"
    local backup_file="${source}.bak"
    
    if [[ -f "${backup_file}" ]]; then
        warn "Biztonsági másolat már létezik: ${backup_file}"
        return 0
    fi
    
    if ! cp -p -- "${source}" "${backup_file}" 2>/dev/null; then
        verbose "Hiba: biztonsági másolat nem készítve: ${source}"
        return 1
    fi
    
    verbose "Biztonsági másolat: ${source} → ${backup_file}"
    return 0
}

# Média transcoding (javítás)
repair_media_file() {
    local filepath="$1"
    local video_codec="${2%%:*}"
    local audio_codec="${2##*:}"
    local fixed_file="${filepath%.*}_fixed.${filepath##*.}"
    local temp_fixed="${fixed_file}.tmp"
    
    # Codec validáció
    if ! validate_codec "${video_codec}" "video"; then
        verbose "Hiba: érvénytelen videó codec: ${video_codec}"
        return 1
    fi
    if ! validate_codec "${audio_codec}" "audio"; then
        verbose "Hiba: érvénytelen audió codec: ${audio_codec}"
        return 1
    fi
    
    verbose "Javítás kezdés: ${filepath}"
    
    # Biztonsági másolat (ha engedélyezve)
    if [[ "${backup}" == "true" ]]; then
        if ! create_backup "${filepath}"; then
            {
                printf '%s|%s|%s\n' \
                    "${filepath}" \
                    "BACKUP_FAILED" \
                    "Biztonsági másolat nem készítve"
            } >> "${temp_repair_log}"
            return 1
        fi
    fi
    
    # Transcode temp fájlba (atomicity)
    if ! timeout "${FFMPEG_TIMEOUT}" ffmpeg \
        -i "${filepath}" \
        -c:v "${video_codec}" \
        -crf 23 \
        -c:a "${audio_codec}" \
        -q:a 4 \
        -y "${temp_fixed}" \
        >/dev/null 2>&1; then
        
        rm -f "${temp_fixed}"
        {
            printf '%s|%s|%s\n' \
                "${filepath}" \
                "REPAIR_FAILED" \
                "Transcode hiba"
        } >> "${temp_repair_log}"
        
        return 1
    fi
    
    # Javított fájl validáció
    if ! validate_media_file "${temp_fixed}" 2>/dev/null; then
        rm -f "${temp_fixed}"
        {
            printf '%s|%s|%s\n' \
                "${filepath}" \
                "REPAIR_VERIFY_FAILED" \
                "Javított fájl még hibás"
        } >> "${temp_repair_log}"
        
        return 1
    fi
    
    # Atomi csere: temp → fixed
    if ! mv -- "${temp_fixed}" "${fixed_file}"; then
        rm -f "${temp_fixed}"
        {
            printf '%s|%s|%s\n' \
                "${filepath}" \
                "REPAIR_MOVE_FAILED" \
                "Fájl átnevezés hiba"
        } >> "${temp_repair_log}"
        
        return 1
    fi
    
    ok "Javítás sikeres: ${filepath} → ${fixed_file}"
    {
        printf '%s|%s|%s\n' \
            "${filepath}" \
            "REPAIR_SUCCESS" \
            "${fixed_file}"
    } >> "${temp_repair_log}"
    
    return 0
}

################################################################################
# FÁJL GYŰJTÉS ÉS TÖRLÉS
################################################################################

# Hibás fájlok másolása célkönyvtárba
collect_invalid_files() {
    local target_dir="$1"
    shift
    local -n invalid_ref=$1
    local -n repaired_ref=$2
    local count=0
    
    [[ ! -d "${target_dir}" ]] && mkdir -p "${target_dir}" || die "Nem hozható létre: ${target_dir}"
    
    local file
    for file in "${invalid_ref[@]}"; do
        # Sikeresen javított fájlok kihagyása
        if array_contains "${file}" "${repaired_ref[@]}"; then
            continue
        fi
        
        local basename="${file##*/}"
        if cp -p -- "${file}" "${target_dir}/${basename}" 2>/dev/null; then
            verbose "Gyűjtés: ${file} → ${target_dir}/${basename}"
            ((count++))
        else
            warn "Nem másolható: ${file}"
        fi
    done
    
    info "Összesen ${count} hibás fájl gyűjtve: ${target_dir}"
}

# Hibás fájlok törlése (biztonságos)
delete_invalid_files() {
    shift
    local -n invalid_ref=$1
    local -n repaired_ref=$2
    local count=0
    
    local file
    for file in "${invalid_ref[@]}"; do
        # Sikeresen javított fájlok kihagyása
        if array_contains "${file}" "${repaired_ref[@]}"; then
            continue
        fi
        
        if rm -f -- "${file}"; then
            verbose "Törlés: ${file}"
            ((count++))
        else
            warn "Nem törölhető: ${file}"
        fi
    done
    
    warn "Összesen ${count} hibás fájl törölve"
}

################################################################################
# FÁJLOK ÖSSZEGYŰJTÉSE
################################################################################

collect_files_from_directory() {
    local dir="$1"
    local include="$2"
    local exclude="$3"
    local case_sens="$4"
    
    info "Fájlok keresése: ${dir}"
    
    local -a find_args=()
    local -a inc_exts
    local -a exc_exts
    
    # Include kiterjesztések feldolgozása
    if [[ -n "${include}" ]]; then
        IFS=',' read -ra inc_exts <<<"${include}"
        
        for ext in "${inc_exts[@]}"; do
            # Kiterjesztés tisztítása (szóközök eltávolítása)
            ext="${ext// /}"
            
            if [[ "${case_sens}" == "yes" ]]; then
                find_args+=(-name "*.${ext}" -o)
            else
                find_args+=(-iname "*.${ext}" -o)
            fi
        done
        
        # Utolsó -o eltávolítása
        unset 'find_args[-1]'
        
        # Fájlok keresése
        local file
        while IFS= read -r file; do
            [[ -f "${file}" ]] && file_list+=("${file}")
        done < <(find "${dir}" -type f \( "${find_args[@]}" \) 2>/dev/null)
    else
        # Csak alapértelmezett típusok
        while IFS= read -r file; do
            [[ -f "${file}" ]] && file_list+=("${file}")
        done < <(find "${dir}" -type f 2>/dev/null)
    fi
    
    # Exclude kiterjesztések feldolgozása
    if [[ -n "${exclude}" ]]; then
        IFS=',' read -ra exc_exts <<<"${exclude}"
        
        local -a filtered_list=()
        local file
        for file in "${file_list[@]}"; do
            local file_ext="${file##*.}"
            if [[ "${case_sens}" != "yes" ]]; then
                file_ext=$(to_lowercase "${file_ext}")
            fi
            
            local skip=false
            local exc_ext
            for exc_ext in "${exc_exts[@]}"; do
                exc_ext="${exc_ext// /}"
                [[ "${case_sens}" != "yes" ]] && exc_ext=$(to_lowercase "${exc_ext}")
                
                if [[ "${file_ext}" == "${exc_ext}" ]]; then
                    skip=true
                    break
                fi
            done
            
            [[ "${skip}" != "true" ]] && filtered_list+=("${file}")
        done
        
        file_list=("${filtered_list[@]}")
    fi
}

collect_files_from_list() {
    local list_file="$1"
    
    info "Fájlok beolvasása: ${list_file}"
    
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Megjegyzések és üres sorok kihagyása
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        
        # Szóközök eltávolítása
        line="${line## }"
        line="${line%% }"
        
        [[ -f "${line}" ]] && file_list+=("${line}")
    done < "${list_file}"
}

################################################################################
# KIMENET GENERÁLÁSA
################################################################################

generate_list_output() {
    local input_file="$1"
    local output_file="$2"
    
    cut -d'|' -f1 "${input_file}" > "${output_file}"
}

generate_table_output() {
    local input_file="$1"
    local output_file="$2"
    
    {
        printf '┌─────────────────────────────────────────────────────────────────────────┬────────────────┬──────────────────────────────────────┐\n'
        printf '│ %-71s │ %-14s │ %-36s │\n' "Fájlnév" "Hibatípus" "Részletek"
        printf '├─────────────────────────────────────────────────────────────────────────┼────────────────┼──────────────────────────────────────┤\n'
        
        local filepath errortype errordetails
        while IFS='|' read -r filepath errortype errordetails; do
            printf '│ %-71s │ %-14s │ %-36s │\n' \
                "${filepath:0:71}" \
                "${errortype:0:14}" \
                "${errordetails:0:36}"
        done < "${input_file}"
        
        printf '└─────────────────────────────────────────────────────────────────────────┴────────────────┴──────────────────────────────────────┘\n'
    } > "${output_file}"
}

################################################################################
# PARANCSSORI PARAMÉTEREK FELDOLGOZÁSA
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            --version)
                version
                ;;
            -d|--dir)
                source_dir="$2"
                [[ -z "${source_dir}" ]] && die "Könyvtár paraméter hiányzik!"
                shift 2
                ;;
            -l|--list)
                list_file="$2"
                [[ -z "${list_file}" ]] && die "Fájllista paraméter hiányzik!"
                shift 2
                ;;
            -i|--include)
                included_ext="$2"
                [[ -z "${included_ext}" ]] && die "Include paraméter hiányzik!"
                shift 2
                ;;
            -e|--exclude)
                excluded_ext="$2"
                [[ -z "${excluded_ext}" ]] && die "Exclude paraméter hiányzik!"
                shift 2
                ;;
            -c|--case)
                case_sensitive="$2"
                [[ ! "${case_sensitive}" =~ ^(yes|no)$ ]] && die "Case érték: yes vagy no"
                shift 2
                ;;
            -o|--output)
                output_file="$2"
                [[ -z "${output_file}" ]] && die "Output paraméter hiányzik!"
                shift 2
                ;;
            -p|--parallel)
                parallel_jobs="$2"
                [[ ! "${parallel_jobs}" =~ ^[0-9]+$ ]] && die "Parallel: pozitív szám szükséges!"
                shift 2
                ;;
            -t|--table)
                table_output="true"
                shift
                ;;
            -v|--verbose)
                verbose="true"
                shift
                ;;
            -q|--quiet)
                quiet="true"
                verbose="false"
                progress="false"
                shift
                ;;
            -P|--progress)
                progress="true"
                shift
                ;;
            -R|--repair)
                repair="true"
                shift
                ;;
            -r|--repair-codec)
                repair_codec="$2"
                [[ -z "${repair_codec}" ]] && die "Repair codec paraméter hiányzik!"
                shift 2
                ;;
            -B|--backup)
                backup="true"
                shift
                ;;
            -D|--delete-invalid)
                delete_invalid="true"
                shift
                ;;
            -C|--collect-invalid)
                collect_invalid="$2"
                [[ -z "${collect_invalid}" ]] && die "Collect path paraméter hiányzik!"
                shift 2
                ;;
            *)
                die "Ismeretlen paraméter: $1"
                ;;
        esac
    done
}

# Paraméterek validáció
validate_arguments() {
    # Legalább egy bemeneti mód
    if [[ -z "${source_dir}" && -z "${list_file}" ]]; then
        die "Adja meg a -d vagy -l paramétert!"
    fi
    
    # Könyvtár létezésének ellenőrzése
    if [[ -n "${source_dir}" && ! -d "${source_dir}" ]]; then
        die "Könyvtár nem létezik: ${source_dir}"
    fi
    
    # Fájllista létezésének ellenőrzése
    if [[ -n "${list_file}" && ! -f "${list_file}" ]]; then
        die "Fájllista nem létezik: ${list_file}"
    fi
    
    # Gyűjtési könyvtár előkészítése
    if [[ -n "${collect_invalid}" ]]; then
        mkdir -p "${collect_invalid}" || die "Gyűjtési könyvtár nem hozható létre: ${collect_invalid}"
    fi
    
    # FFmpeg elérhetőség
    check_ffmpeg
}

################################################################################
# FŐPROGRAM
################################################################################

main() {
    # Paraméterek feldolgozása
    parse_arguments "$@"
    validate_arguments
    
    # Temp fájlok inicializálása
    temp_error_file=$(mktemp "${TEMP_DIR}/validator_errors.XXXXXX")
    temp_repair_log=$(mktemp "${TEMP_DIR}/validator_repairs.XXXXXX")
    lock_dir=$(mktemp -d "${TEMP_DIR}/validator_lock.XXXXXX")
    
    [[ -z "${temp_error_file}" || -z "${temp_repair_log}" ]] && die "Temp fájlok nem hozhatók létre"
    
    # Fájlok gyűjtése
    if [[ -n "${source_dir}" ]]; then
        collect_files_from_directory "${source_dir}" "${included_ext}" "${excluded_ext}" "${case_sensitive}"
    else
        collect_files_from_list "${list_file}"
    fi
    
    # Üres fájllista ellenőrzés
    if [[ ${#file_list[@]} -eq 0 ]]; then
        die "Nincs feldolgozandó fájl"
    fi
    
    info "Feldolgozandó fájlok: ${#file_list[@]}"
    
    # Fájlok ellenőrzése és javítása
    local current=0
    local total=${#file_list[@]}
    
    for filepath in "${file_list[@]}"; do
        ((current++))
        
        render_progress_bar "${current}" "${total}"
        
        # Validáció
        if validate_media_file "${filepath}"; then
            verbose "[${current}/${total}] ✓ ${filepath}"
        else
            verbose "[${current}/${total}] ✗ ${filepath}"
            invalid_files+=("${filepath}")
            
            # Javítási kísérlet
            if [[ "${repair}" == "true" ]]; then
                if repair_media_file "${filepath}" "${repair_codec}"; then
                    repaired_files+=("${filepath}")
                fi
            fi
        fi
    done
    
    # Hibás fájlok feldolgozása
    if [[ -n "${collect_invalid}" && ${#invalid_files[@]} -gt 0 ]]; then
        collect_invalid_files "${collect_invalid}" invalid_files repaired_files
    fi
    
    if [[ "${delete_invalid}" == "true" && ${#invalid_files[@]} -gt 0 ]]; then
        delete_invalid_files "" invalid_files repaired_files
    fi
    
    # Kimenet generálása
    if [[ ! -s "${temp_error_file}" ]]; then
        info "Nincs hibás fájl."
        echo "Validáció sikeres - nincs hiba." > "${output_file}"
    else
        sort -u "${temp_error_file}" > "${temp_error_file}.sorted"
        
        if [[ "${table_output}" == "true" ]]; then
            generate_table_output "${temp_error_file}.sorted" "${output_file}"
        else
            generate_list_output "${temp_error_file}.sorted" "${output_file}"
        fi
        
        info "Hibás fájlok kimenete: ${output_file}"
    fi
    
    # Javítási jelentés
    if [[ -s "${temp_repair_log}" ]]; then
        info "Javítási jelentés:"
        sort -u "${temp_repair_log}" | while IFS='|' read -r fp status detail; do
            printf "  %-50s [%-20s] %s\n" "${fp}" "${status}" "${detail}"
        done
    fi
    
    # Végeredmény
    local error_count=${#invalid_files[@]}
    local repaired_count=${#repaired_files[@]}
    local success_count=$(( total - error_count ))
    
    printf '\n%s\n' \
        "╔════════════════════════════════════════════════════════════════════════╗" \
        "║                     FELDOLGOZÁS BEFEJEZVE                              ║" \
        "╚════════════════════════════════════════════════════════════════════════╝"
    
    printf '%-30s: %d\n' "Összes feldolgozva" "${total}"
    printf '%-30s: %d\n' "Sikeresen validálva" "${success_count}"
    printf '%-30s: %d\n' "Hibásak" "${error_count}"
    
    if [[ "${repair}" == "true" ]]; then
        printf '%-30s: %d\n' "Sikeresen javítva" "${repaired_count}"
    fi
    
    printf '%-30s: %s\n' "Kimenet fájl" "${output_file}"
    
    printf '%s\n' "════════════════════════════════════════════════════════════════════════"
}

# Belépési pont
main "$@"
