#!/usr/bin/env bash
# Check Kernel for the newest version (c) 2005-2026 by FNH media KG
# (c) 2005 by Frank Niederhausen for FNH
# (c) 2016-2026 by Frank Beckmann
#
# BASE VERSION: v0.13
# THIS VERSION: v2.0.25

set -euo pipefail
IFS=$'\n\t'

export KERNELHOST="https://www.kernel.org"
export KERNELFILE="linux-"
export KERNELTAIL=".tar.xz"
export TMPKRN="/tmp/linuxkrntmp"
export KERNELPATH="/pub/linux/kernel/"
export CURVER="$(uname -r)"
export CURVER2="$(uname -r | cut -f1 -d-)"
export CURVER3="$(uname -r)"
export CPUTYPE=""
export HOST_CPUTYPE=""
export CPU_EXPLICIT="0"
export CLEAN_BUILD="0"
export CHANGE_CPU="0"
export STAGING="0"
export DRY_RUN="0"
export LOG_FILE=""
export LOCK_FILE="/run/lock/check_kernel.lock"
PHASE="initialization"

NPROC=$(nproc 2>/dev/null || echo 1)

if [ "$NPROC" -le 1 ]; then
  export BULDCPU=1
else
  export BULDCPU=$((NPROC - 1))
fi

export MAKEPARM="-j$BULDCPU"

SCRIPTVERSION="v2.0.25"

echo "Check Kernel ${SCRIPTVERSION}  (c) 2005-2026 by FNH media KG"

show_usage() {
  echo "Check Kernel:"
  echo "Mögliche Parameter:"
  echo "-A|--amd|-amd       Kernel für AMD bauen, Ziel: /usr/src/linux-%KERNELVERSION%-amd"
  echo "-I|-i|--intel|-intel Kernel für Intel bauen, Ziel: /usr/src/linux-%KERNELVERSION%-intel"
  echo "-t <tree>           Eingabe des Kernel Trees, z.B.: -t 6.12"
  echo "-k <version>        Exakten Kernel verwenden, z.B.: -k 6.12.90"
  echo "-m                  Aktuellen Kernel holen und menuconfig starten"
  echo "-l|--list           Aktuell verfügbare Kernel-Zweige von kernel.org anzeigen"
  echo "--clean             Kernel-Tree vor dem Build mit make clean bereinigen"
  echo "--log <file>        Ausgabe zusätzlich in eine Logdatei schreiben"
  echo "--list-installed    Installierte Kernel anzeigen"
  echo "--remove <version>  Installierten Kernel nach Bestätigung entfernen"
  echo "--change-cpu        Cross-CPU-Kernel als nächsten Bootkernel setzen"
  echo "                    Mit -A/-I: Kernel interaktiv auswählen und für diesen CPU-Typ bauen"
  echo "-h                  Hilfe anzeigen"
  echo
  echo "Beispiele:"
  echo "$0 -A -t 6.12"
  echo "$0 --intel -k 6.12.90"
  echo "$0 -A"
  echo "$0 -I -m"
  echo "$0 -i --change-cpu"
  echo "$0 --list"
  echo "$0 -A -l"
  echo "$0 -I --list"
  echo "$0 -A -t 6.12 --clean"
}


print_info() {
  local label="$1"
  local value="$2"
  local padded

  padded="$(printf "%s" "$label" | sed 's/$/.............................. /' | cut -c1-30)"
  printf "%s: %s
" "$padded" "$value"
}

get_available_kernel_entries() {
  local banner

  banner="$(curl -ks "${KERNELHOST}/finger_banner")"

  if [ -z "$banner" ]; then
    echo "Could not retrieve kernel list from ${KERNELHOST}." >&2
    return 1
  fi

  # Output format: label|version
  # stable/mainline/stable <tree> stay on top.
  # longterm entries are sorted ascending by kernel tree version.
  {
    echo "$banner" | awk '
      /Linux kernel is:/ {
        line=$0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        label=line
        version=line

        sub(/^The latest[[:space:]]+/, "", label)
        sub(/[[:space:]]+version of the Linux kernel is:[[:space:]]*.*/, "", label)
        sub(/^.*Linux kernel is:[[:space:]]*/, "", version)
        gsub(/[[:space:]]+/, "", version)

        if (version ~ /^[0-9]+\.[0-9]+/ && label !~ /^longterm/) {
          print label "|" version
        }
      }
    '

    echo "$banner" | awk '
      /Linux kernel is:/ {
        line=$0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        label=line
        version=line

        sub(/^The latest[[:space:]]+/, "", label)
        sub(/[[:space:]]+version of the Linux kernel is:[[:space:]]*.*/, "", label)
        sub(/^.*Linux kernel is:[[:space:]]*/, "", version)
        gsub(/[[:space:]]+/, "", version)

        if (version ~ /^[0-9]+\.[0-9]+/ && label ~ /^longterm/) {
          print label "|" version
        }
      }
    ' | sort -t'|' -k1,1V
  }
}

mark_current_tree_label() {
  local label="$1"
  local current_tree

  current_tree="$(uname -r | cut -f1 -d- | cut -f1-2 -d.)"

  case "$label" in
    "stable ${current_tree}"|"longterm ${current_tree}")
      printf "%s [current]" "$label"
      ;;
    *)
      printf "%s" "$label"
      ;;
  esac
}

list_available_kernels() {
  local entries

  if ! entries="$(get_available_kernel_entries)"; then
    echo "No matching kernel entries found in finger_banner."
    exit 1
  fi

  echo "Available kernels"
  echo "$entries" | while IFS='|' read -r label version; do
    [ -n "${label:-}" ] || continue
    print_info "$(mark_current_tree_label "$label")" "$version"
  done
}

select_kernel_from_list() {
  local entries
  local count
  local choice
  local selected

  if ! entries="$(get_available_kernel_entries)"; then
    echo "No matching kernel entries found in finger_banner."
    exit 1
  fi

  echo "Available kernels"
  echo "$entries" | awk -F'|' '{ printf "%s|%s|%s\n", $1, $2, NR }' | while IFS='|' read -r label version number; do
    [ -n "${label:-}" ] || continue
    print_info "${number}. $(mark_current_tree_label "$label")" "$version"
  done

  count="$(echo "$entries" | awk 'END { print NR }')"

  while true; do
    printf 'Select kernel to build for %s [1-%s, q=quit]: ' "$CPUTYPE" "$count"
    read -r choice

    case "$choice" in
      q|Q|quit|exit)
        echo "aborted."
        exit 0
        ;;
      ''|*[!0-9]*)
        echo "Invalid selection: ${choice:-<empty>}"
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
          selected="$(echo "$entries" | awk -F'|' -v n="$choice" 'NR == n { print $2 }')"
          if [ -n "$selected" ]; then
            KERNELVER="$selected"
            ONLINEVER="$selected"
            export KERNELVER ONLINEVER
            return 0
          fi
        fi
        echo "Invalid selection: $choice"
        ;;
    esac
  done
}

require_list_cmds() {
  local missing=0
  local cmd

  for cmd in curl awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd"
      missing=1
    fi
  done

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

detect_cpu_type() {
  if [ -r /proc/cpuinfo ]; then
    if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
      echo "amd"
      return 0
    fi

    if grep -qi 'GenuineIntel' /proc/cpuinfo; then
      echo "intel"
      return 0
    fi
  fi

  echo ""
}

parse_global_args() {
  ARGS_TEXT=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -A|--amd|-amd|.A|.amd)
        CPUTYPE="amd"
        CPU_EXPLICIT="1"
        ;;
      -I|-i|--intel|-intel|.I|.i|.intel)
        CPUTYPE="intel"
        CPU_EXPLICIT="1"
        ;;
      --clean)
        CLEAN_BUILD="1"
        ;;
      --staging)
        STAGING="1"
        ;;
      --dry-run)
        DRY_RUN="1"
        ;;
      --log)
        shift
        if [ "$#" -eq 0 ]; then
          echo "Missing log file after --log" >&2
          exit 1
        fi
        LOG_FILE="$1"
        ;;
      --change-cpu|--change-CPU|--changeCPU|--change_cpu|--chage-CPU)
        CHANGE_CPU="1"
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          ARGS_TEXT="${ARGS_TEXT}${ARGS_TEXT:+
}$1"
          shift
        done
        break
        ;;
      *)
        ARGS_TEXT="${ARGS_TEXT}${ARGS_TEXT:+
}$1"
        ;;
    esac
    shift || true
  done

  export CPUTYPE CPU_EXPLICIT CLEAN_BUILD CHANGE_CPU STAGING DRY_RUN LOG_FILE ARGS_TEXT
}
init_cpu_type() {
  HOST_CPUTYPE="$(detect_cpu_type)"

  if [ -z "${CPUTYPE:-}" ]; then
    CPUTYPE="$HOST_CPUTYPE"
  fi

  if [ -z "${CPUTYPE:-}" ]; then
    echo "Could not detect CPU vendor from /proc/cpuinfo. Use -A/--amd or -I/--intel."
    exit 1
  fi

  if [ -z "${HOST_CPUTYPE:-}" ]; then
    print_info "Host CPU" "unknown"
  fi

  export CPUTYPE HOST_CPUTYPE
}

is_cross_cpu_build() {
  [ -n "${HOST_CPUTYPE:-}" ] && [ "${CPUTYPE:-}" != "${HOST_CPUTYPE:-}" ]
}

should_set_boot_symlinks() {
  if is_cross_cpu_build; then
    [ "${CHANGE_CPU:-0}" = "1" ]
    return $?
  fi

  return 0
}

kernel_srcdir() {
  local version="$1"
  echo "/usr/src/linux-${version}-${CPUTYPE}"
}

kernel_build_name() {
  local version="$1"
  echo "linux-${version}-${CPUTYPE}"
}

show_kernel_target() {
  local version="$1"
  print_info "Host CPU" "${HOST_CPUTYPE:-unknown}"
  print_info "CPU target" "$CPUTYPE"
  print_info "Kernel build" "$(kernel_build_name "$version")"
  print_info "Source path" "$(kernel_srcdir "$version")"

  if is_cross_cpu_build; then
    if [ "${CHANGE_CPU:-0}" = "1" ]; then
      print_info "Boot symlinks" "forced for CPU change"
    else
      print_info "Boot symlinks" "skipped for cross-CPU build"
    fi
  else
    print_info "Boot symlinks" "enabled"
  fi
}

run_optional_clean() {
  if [ "${CLEAN_BUILD:-0}" = "1" ]; then
    print_info "Clean build" "make clean"
    make clean
  fi
}
get_latest_boot_config() {
  local target_cpu="${1:-}"
  local config_file

  # Cross-CPU builds should prefer the last matching CPU-specific boot config.
  if [ -n "$target_cpu" ] && [ -n "${HOST_CPUTYPE:-}" ] && [ "$target_cpu" != "$HOST_CPUTYPE" ]; then
    config_file="$(ls -1t /boot/config-* 2>/dev/null | awk -v cpu="$target_cpu" 'tolower($0) ~ cpu { print; exit }' || true)"
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
      echo "$config_file"
      return 0
    fi

    print_info "Config warning" "no /boot/config-*${target_cpu} found, using newest available config" >&2
  fi

  if [ -f "/boot/config-${CURVER3}" ]; then
    echo "/boot/config-${CURVER3}"
    return 0
  fi

  if [ "${CURVER2:-}" != "" ] && [ -f "/boot/config-${CURVER2}" ]; then
    echo "/boot/config-${CURVER2}"
    return 0
  fi

  if [ -n "$target_cpu" ]; then
    config_file="$(ls -1t /boot/config-* 2>/dev/null | awk -v cpu="$target_cpu" 'tolower($0) ~ cpu { print; exit }' || true)"
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
      echo "$config_file"
      return 0
    fi
  fi

  config_file="$(ls -1t /boot/config-* 2>/dev/null | head -n 1 || true)"
  if [ -n "$config_file" ] && [ -f "$config_file" ]; then
    echo "$config_file"
    return 0
  fi

  return 1
}

copy_latest_boot_config() {
  local srcdir="$1"
  local boot_config

  if ! boot_config="$(get_latest_boot_config "$CPUTYPE")"; then
    echo "No /boot/config-* found."
    return 1
  fi

  print_info "Restoring config" "$boot_config"
  cp "$boot_config" "${srcdir}/.config"
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
  fi

  mkdir -p "$(dirname "$LOCK_FILE")"
  if ! command -v flock >/dev/null 2>&1; then
    echo "Missing required command: flock"
    exit 1
  fi
  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    echo "Another check_kernel process is already running: $LOCK_FILE" >&2
    exit 1
  fi
}

require_cmds() {
  local missing=0
  local cmd

  for cmd in curl wget tar make grep cut sed awk uname nproc sha256sum update-initramfs update-grub; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd"
      missing=1
    fi
  done

  if ! command -v pv >/dev/null 2>&1; then
    echo "Warning: pv not found, extraction will continue without progress bar."
  fi

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

cleanup_tmp() {
  if [ -n "${TMPKRN:-}" ] && [ "$TMPKRN" != "/" ] && [ -d "$TMPKRN" ]; then
    rm -rf -- "$TMPKRN"
  fi
}

on_error() {
  local status=$?
  echo "ERROR: phase=${PHASE}, line=${BASH_LINENO[0]:-unknown}, status=${status}" >&2
  exit "$status"
}

trap cleanup_tmp EXIT
trap on_error ERR

download_kernel_archive() {
  local url="$1"
  local archive="$2"
  local checksum_url="$3"
  local part="${archive}.part"
  local archive_name="${archive##*/}"
  local checksums expected actual

  PHASE="download"
  if [ ! -s "$archive" ]; then
    print_info "Download" "$url"
    wget -c -O "$part" "$url"
    mv -f -- "$part" "$archive"
  fi

  PHASE="verify-download"
  checksums="$(curl -fsSL "$checksum_url")" || {
    echo "Could not retrieve checksum list: $checksum_url" >&2
    return 1
  }
  expected="$(printf '%s\n' "$checksums" | awk -v file="$archive_name" '$NF == file { print $1; exit }')"
  if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "No SHA256 checksum found for $archive" >&2
    return 1
  fi
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "SHA256 verification failed for $archive" >&2
    return 1
  fi
  print_info "SHA256" "verified"
}

extract_kernel_archive() {
  local archive="$1"
  local version="$2"
  local srcdir

  srcdir="$(kernel_srcdir "$version")"

  PHASE="extract"
  print_info "Extract archive" "$archive"
  print_info "Extract target" "$srcdir"
  rm -rf "$srcdir"
  mkdir -p "$srcdir"

  if command -v pv >/dev/null 2>&1; then
    pv -p "$archive" | tar xfJ - -C "$srcdir" --strip-components=1
  else
    tar xfJ "$archive" -C "$srcdir" --strip-components=1
  fi
}

get_config_localversion() {
  local config_file="$1"

  if [ -f "$config_file" ]; then
    grep '^CONFIG_LOCALVERSION=' "$config_file" | cut -d'"' -f2 | tr -d '[:space:]' || true
  fi
}

finish_kernel_install() {
  local version="$1"
  local config_localversion="$2"
  local srcdir="$3"
  local mode="${4:-}"
  local kernel_id="${version}${config_localversion}"

  cp "$srcdir/arch/x86/boot/bzImage" "/boot/vmlinuz-${kernel_id}"
  cp "$srcdir/.config" "/boot/config-${kernel_id}"

  echo "creating ramdisk for kernel"
  print_info "Initramfs kernel" "$kernel_id"
  if [ -e "/boot/initrd.img-${kernel_id}" ]; then
    update-initramfs -k "$kernel_id" -u -t
  else
    update-initramfs -k "$kernel_id" -c
  fi

  if should_set_boot_symlinks || [ "${CHANGE_CPU:-0}" = "1" ]; then
    if is_cross_cpu_build && [ "${CHANGE_CPU:-0}" = "1" ]; then
      print_info "CPU change" "forced, setting new boot symlinks"
    else
      print_info "Boot symlinks" "setting new boot symlinks"
    fi

    rm -f /boot/vmlinuz /boot/vmlinuz.old /usr/src/linux
    ln -sfn "vmlinuz-${kernel_id}" /boot/vmlinuz
    ln -sfn "vmlinuz-${CURVER3}" /boot/vmlinuz.old
    ln -sfn "$srcdir" /usr/src/linux

    rm -f /boot/initrd.img /boot/initrd.img.old
    ln -sfn "initrd.img-${kernel_id}" /boot/initrd.img
    ln -sfn "initrd.img-${CURVER3}" /boot/initrd.img.old
  else
    print_info "Boot symlinks" "not changed"
    print_info "Reason" "cross-CPU build without --change-cpu"
  fi

  update-grub
  echo "done...."
}

install_kernel() {
  local srcdir
  srcdir="$(kernel_srcdir "$ONLINEVER")"

  if [ -d "$srcdir" ]; then
    echo "kernel source already exists on disk: ${srcdir}"
    return
  fi

  mkdir -p "$TMPKRN"
  cd "$TMPKRN"

  echo "retrieving kernel from server ..."
  echo "getting ${KERNELHOST}${KERNELPATH}${KERNELSUB2}${KERNELFILE}${ONLINEVER}${KERNELTAIL}"
  download_kernel_archive \
    "${KERNELHOST}${KERNELPATH}${KERNELSUB2}${KERNELFILE}${ONLINEVER}${KERNELTAIL}" \
    "${KERNELFILE}${ONLINEVER}${KERNELTAIL}" \
    "${KERNELHOST}${KERNELPATH}${KERNELSUB2}sha256sums.asc"

  extract_kernel_archive "${KERNELFILE}${ONLINEVER}${KERNELTAIL}" "$ONLINEVER"
}

install_kernel_minusk() {
  local srcdir
  srcdir="$(kernel_srcdir "$KERNELVER")"

  if [ -d "$srcdir" ]; then
    echo "kernel source already exists on disk: ${srcdir}"
    return
  fi

  mkdir -p "$TMPKRN"
  cd "$TMPKRN"

  echo "retrieving kernel from server ..."
  echo "getting ${KERNELHOST}${KERNELPATH}${KERNELSUB2}${KERNELFILE}${KERNELVER}${KERNELTAIL}"
  download_kernel_archive \
    "${KERNELHOST}${KERNELPATH}${KERNELSUB2}${KERNELFILE}${KERNELVER}${KERNELTAIL}" \
    "${KERNELFILE}${KERNELVER}${KERNELTAIL}" \
    "${KERNELHOST}${KERNELPATH}${KERNELSUB2}sha256sums.asc"

  extract_kernel_archive "${KERNELFILE}${KERNELVER}${KERNELTAIL}" "$KERNELVER"
}

config_kernel2() {
  local srcdir
  local config_localversion

  srcdir="$(kernel_srcdir "$ONLINEVER")"
  cd "$srcdir"

  if [ "${MANUAL:-}" = "-menuconfig" ] || [ "${1:-}" = "-t" ] || [ "${1:-}" = "-m" ]; then
    echo "running menuconfig..."
    make menuconfig
  fi

  config_localversion="$(get_config_localversion "$srcdir/.config")"
  print_info "Building kernel" "${ONLINEVER}${config_localversion}"
  print_info "Source path" "$srcdir"

  run_optional_clean

  make "$MAKEPARM" bzImage
  make "$MAKEPARM" modules
  make "$MAKEPARM" modules_install

  config_localversion="$(get_config_localversion "$srcdir/.config")"

  finish_kernel_install "$ONLINEVER" "$config_localversion" "$srcdir" "${1:-}"
  exit 0
}

config_kernel_minusk() {
  local srcdir
  local config_localversion

  srcdir="$(kernel_srcdir "$KERNELVER")"
  cd "$srcdir"

  if [ ! -f "$srcdir/.config" ]; then
    copy_latest_boot_config "$srcdir" || exit 1
    echo "reconfig old config file"
    make olddefconfig
  fi

  make menuconfig

  config_localversion="$(get_config_localversion "$srcdir/.config")"
  print_info "Building kernel" "${KERNELVER}${config_localversion}"
  print_info "Source path" "$srcdir"

  run_optional_clean

  make "$MAKEPARM" bzImage
  make "$MAKEPARM" modules
  make "$MAKEPARM" modules_install

  config_localversion="$(get_config_localversion "$srcdir/.config")"

  finish_kernel_install "$KERNELVER" "$config_localversion" "$srcdir" "-k"
}

config_kernel() {
  local srcdir
  srcdir="$(kernel_srcdir "$ONLINEVER")"

  cd "$srcdir"

  if [ ! -f "$srcdir/.config" ]; then
    copy_latest_boot_config "$srcdir" || exit 1
    echo "copy old Kernel config to ${srcdir}"
    echo "reconfig old config file"
    make olddefconfig
  fi

  print_info "Source path" "$srcdir"
  print_info "Local version" "$(get_config_localversion "$srcdir/.config")"
  config_kernel2
  exit 0
}

# Staging mode is intentionally isolated from the normal installation path.
# In particular, it does not regenerate grub.cfg: with GRUB_DEFAULT=0 doing
# so can silently change the default kernel even when all symlinks are intact.
staging_config_candidates() {
  local cpu="$1" file base
  local -a matching=() other=()
  shopt -s nullglob
  for file in /boot/config-*; do
    [ -f "$file" ] || continue
    base="${file##*/}"
    if [[ "${base,,}" == *"$cpu"* ]]; then matching+=("$file"); else other+=("$file"); fi
  done
  for file in /usr/src/linux-*/.config; do
    [ -f "$file" ] || continue
    base="${file%/.config}"; base="${base##*/}"
    if [[ "${base,,}" == *"$cpu"* ]]; then matching+=("$file"); else other+=("$file"); fi
  done
  shopt -u nullglob
  # Matching CPU first, then other existing configs. All options remain selectable.
  printf '%s\n' "${matching[@]}" | sed '/^$/d' | sort -u -V
  printf '%s\n' "${other[@]}" | sed '/^$/d' | sort -u -V
}

select_staging_config() {
  local cpu="$1" choice path idx
  local -a configs=()
  mapfile -t configs < <(staging_config_candidates "$cpu")
  echo >&2
  echo "Config selection for ${cpu^^}" >&2
  echo '------------------------------------------------' >&2
  for idx in "${!configs[@]}"; do
    printf '%2d. %s\n' "$((idx+1))" "${configs[$idx]}" >&2
  done
  printf '%2d. Enter custom config path\n' "$((${#configs[@]}+1))" >&2
  printf '%2d. Abort\n' "$((${#configs[@]}+2))" >&2
  while true; do
    printf 'Select config [1-%d]: ' "$((${#configs[@]}+2))" >&2
    IFS= read -r choice </dev/tty || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#configs[@]} )); then
      printf '%s\n' "${configs[$((10#$choice-1))]}"
      return 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice == ${#configs[@]}+1 )); then
      printf 'Config path: ' >&2
      IFS= read -r path </dev/tty || return 1
      if [ -f "$path" ] && [ -r "$path" ]; then printf '%s\n' "$path"; return 0; fi
      echo "Config not readable: $path" >&2
      continue
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice == ${#configs[@]}+2 )); then return 1; fi
    echo 'Invalid selection.' >&2
  done
}

staging_kernel_release() {
  local cpu="$1" version="$2" srcdir="$3" release
  # Force separate module trees even when the selected configs have identical
  # CONFIG_LOCALVERSION values. Clear LOCALVERSION_AUTO to avoid git suffixes.
  sed -i -E 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-FNH-'"${cpu^^}"'"/' "$srcdir/.config"
  if ! grep -q '^CONFIG_LOCALVERSION=' "$srcdir/.config"; then
    printf 'CONFIG_LOCALVERSION="-FNH-%s"\n' "${cpu^^}" >> "$srcdir/.config"
  fi
  if grep -q '^CONFIG_LOCALVERSION_AUTO=' "$srcdir/.config"; then
    sed -i 's/^CONFIG_LOCALVERSION_AUTO=.*/# CONFIG_LOCALVERSION_AUTO is not set/' "$srcdir/.config"
  else
    echo '# CONFIG_LOCALVERSION_AUTO is not set' >> "$srcdir/.config"
  fi
  ( cd "$srcdir" && make olddefconfig >/dev/null )
  release="$(cd "$srcdir" && make -s kernelrelease)"
  case "$release" in
    "${version}-FNH-${cpu^^}") printf '%s\n' "$release" ;;
    *) echo "Unexpected kernel release: $release (expected ${version}-FNH-${cpu^^})" >&2; return 1 ;;
  esac
}

staging_download_sources() {
  local cpu="$1" version="$2" srcdir archive url
  CPUTYPE="$cpu"
  srcdir="$(kernel_srcdir "$version")"
  if [ -f "$srcdir/Makefile" ]; then
    print_info 'Source reused' "$srcdir"
    return 0
  fi
  if [ -e "$srcdir" ]; then
    echo "Incomplete source directory exists: $srcdir" >&2
    return 1
  fi
  archive="${KERNELFILE}${version}${KERNELTAIL}"
  url="${KERNELHOST}${KERNELPATH}v${version%%.*}.x/${archive}"
  mkdir -p "$TMPKRN"
  download_kernel_archive \
    "$url" \
    "$TMPKRN/$archive" \
    "${KERNELHOST}${KERNELPATH}v${version%%.*}.x/sha256sums.asc"
  extract_kernel_archive "$TMPKRN/$archive" "$version"
}

run_staging() {
  local version="" tree cpu srcdir release config
  local amd_config intel_config
  local -a target_cpus=(amd intel)
  if [ ! -f /etc/staging_fnh ]; then
    echo 'ERROR: --staging requires /etc/staging_fnh' >&2; exit 1
  fi
  if [ "$CHANGE_CPU" = 1 ]; then
    echo 'ERROR: --change-cpu is forbidden with --staging' >&2; exit 1
  fi
  if [ "$CPU_EXPLICIT" = 1 ]; then
    target_cpus=("$CPUTYPE")
  fi
  case "${1:-}" in
    '')
      tree="$(uname -r | cut -d- -f1 | cut -d. -f1-2)"
      ;;
    -t|-T)
      tree="${2:-}"
      [[ "$tree" =~ ^[0-9]+\.[0-9]+$ ]] || { echo 'Invalid tree (-t)' >&2; exit 1; }
      ;;
    -k|-K)
      version="${2:-}"
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version (-k)' >&2; exit 1; }
      ;;
    -m|-M)
      tree="$(uname -r | cut -d- -f1 | cut -d. -f1-2)"
      ;;
    *) echo 'Staging supports -m, -t TREE, -k VERSION or no additional option.' >&2; exit 1 ;;
  esac
  if [ -z "$version" ]; then
    local entries
    entries="$(get_available_kernel_entries)" || exit 1
    version="$(printf '%s\n' "$entries" | awk -F'|' -v t="$tree" '$2 ~ ("^"t"\.") {print $2; exit}')"
    if [ -z "$version" ]; then
      echo "No kernel version found for tree $tree" >&2; exit 1
    fi
  fi
  require_root
  require_cmds
  [ -r /dev/tty ] || { echo 'Staging requires an interactive terminal.' >&2; exit 1; }
  print_info 'Staging mode' 'enabled'
  if [ -f /etc/staging_fnh ]; then
    print_info 'STAGING' "$STAGING"
    print_info 'CPU_EXPLICIT' "$CPU_EXPLICIT"
    print_info 'CHANGE_CPU' "$CHANGE_CPU"
    print_info 'CLEAN_BUILD' "$CLEAN_BUILD"
  fi
  print_info 'Host CPU' "${HOST_CPUTYPE:-unknown}"
  print_info 'Kernel version' "$version"
  print_info 'Boot selection' 'will not be changed'
  print_info 'GRUB config' 'will not be regenerated (protects default boot)'
  # Collect all required selections before downloading/building any kernel.
  for cpu in "${target_cpus[@]}"; do
    if [ "$cpu" = amd ]; then
      amd_config="$(select_staging_config amd)" || { echo 'Staging aborted.' >&2; exit 1; }
    else
      intel_config="$(select_staging_config intel)" || { echo 'Staging aborted.' >&2; exit 1; }
    fi
  done
  for cpu in "${target_cpus[@]}"; do
    if [ "$cpu" = amd ]; then config="$amd_config"; else config="$intel_config"; fi
    print_info 'CPU target' "$cpu"
    print_info 'Selected config' "$config"
    staging_download_sources "$cpu" "$version"
    srcdir="$(kernel_srcdir "$version")"
    cp "$config" "$srcdir/.config"
    ( cd "$srcdir" && make olddefconfig )
    echo "Running menuconfig for ${cpu^^}..."
    ( cd "$srcdir" && make menuconfig )
    release="$(staging_kernel_release "$cpu" "$version" "$srcdir")" || exit 1
    print_info 'Kernel release' "$release"
    # Replacing an existing staging kernel requires explicit confirmation.
    if [ -e "/boot/vmlinuz-${release}" ] || [ -e "/lib/modules/${release}" ]; then
      if [ "$release" = "$(uname -r)" ]; then
        echo "WARNING: ${release} is the currently running kernel."
        echo "Replacing its files affects the next boot and future module loads."
      fi
      printf 'Kernel %s is already installed. Replace it? [yes/NO] ' "$release"
      read -r replace_choice
      if [ "$replace_choice" != yes ]; then
        echo "Keeping existing kernel: ${release}"
        exit 0
      fi
      print_info 'Replacing existing kernel' "$release"
      rm -f -- \
        "/boot/vmlinuz-${release}" \
        "/boot/config-${release}" \
        "/boot/initrd.img-${release}"
      rm -rf -- "/lib/modules/${release}"
    fi
    ( cd "$srcdir" &&
      if [ "$CLEAN_BUILD" = 1 ]; then make clean; fi &&
      make "$MAKEPARM" bzImage &&
      make "$MAKEPARM" modules &&
      make "$MAKEPARM" modules_install )
    install -m 0644 "$srcdir/arch/x86/boot/bzImage" "/boot/vmlinuz-${release}"
    install -m 0644 "$srcdir/.config" "/boot/config-${release}"
    if [ -e "/boot/initrd.img-${release}" ]; then
      echo "ERROR: initramfs already exists for ${release}; refusing overwrite" >&2; exit 1
    fi
    update-initramfs -c -k "$release"
    print_info 'Installed' "$release"
  done
  echo 'Staging finished. Boot symlinks, GRUB defaults and grub.cfg are unchanged.'
  echo 'Note: The new kernels are not added to the GRUB menu automatically.'
  echo 'Do not run update-grub without checking GRUB_DEFAULT first.'
}

list_installed_kernels() {
  local image version
  local found=0
  shopt -s nullglob
  for image in /boot/vmlinuz-*; do
    [ -f "$image" ] || continue
    version="${image##*/vmlinuz-}"
    if [ "$version" = "$(uname -r)" ]; then
      printf '%s (running)\n' "$version"
    else
      printf '%s\n' "$version"
    fi
    found=1
  done | sort -V
  shopt -u nullglob
  if [ "$found" -eq 0 ]; then
    echo 'No installed kernels found.'
  fi
}

remove_installed_kernel() {
  local version="$1"
  local current="$(uname -r)"

  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+[-+._A-Za-z0-9]*$ ]]; then
    echo "Invalid kernel version: $version" >&2
    return 1
  fi
  if [ "$version" = "$current" ]; then
    echo "Refusing to remove the running kernel: $current" >&2
    return 1
  fi
  if [ ! -e "/boot/vmlinuz-$version" ] && [ ! -e "/lib/modules/$version" ]; then
    echo "Kernel is not installed: $version" >&2
    return 1
  fi

  echo "The following will be removed:"
  printf '  /boot/vmlinuz-%s\n  /boot/config-%s\n  /boot/initrd.img-%s\n  /lib/modules/%s\n' \
    "$version" "$version" "$version" "$version"
  printf 'Remove kernel %s? [yes/NO] ' "$version"
  read -r choice
  [ "$choice" = yes ] || { echo 'aborted.'; return 0; }

  PHASE="remove"
  rm -f -- "/boot/vmlinuz-$version" "/boot/config-$version" "/boot/initrd.img-$version"
  rm -rf -- "/lib/modules/$version"
  update-grub
  echo "Removed kernel: $version"
}

parse_global_args "$@"

if [ -n "$LOG_FILE" ]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

if [ "$DRY_RUN" = "1" ]; then
  print_info "Dry run" "enabled"
  print_info "CPU target" "${CPUTYPE:-auto}"
  print_info "Arguments" "${ARGS_TEXT:-default workflow}"
  exit 0
fi

set --
if [ -n "${ARGS_TEXT:-}" ]; then
  while IFS= read -r arg; do
    set -- "$@" "$arg"
  done <<EOF
${ARGS_TEXT}
EOF
fi

case "${1:-}" in
  -t|-T)
    if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid kernel tree version: ${2:-<missing>}" >&2
      exit 1
    fi
    ;;
  -k|-K)
    if [ -z "${2:-}" ] || [[ ! "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid kernel version: ${2:-<missing>}" >&2
      exit 1
    fi
    ;;
esac

case "${1:-}" in
  --list-installed)
    list_installed_kernels
    exit 0
    ;;
  --remove)
    require_root
    if [ -z "${2:-}" ]; then
      echo 'Missing kernel version after --remove' >&2
      exit 1
    fi
    require_cmds
    remove_installed_kernel "$2"
    exit $?
    ;;
esac

if [ "$STAGING" = 1 ]; then
  init_cpu_type
  run_staging "$@"
  exit $?
fi

case "${1:-}" in
  -l|-L|--list|list)
    require_list_cmds

    if [ "${CPU_EXPLICIT:-0}" = "1" ]; then
      init_cpu_type
      require_root
      require_cmds
      select_kernel_from_list

      KERNELSUB="$(echo "$KERNELVER" | cut -f1 -d'.')"
      KERNELSUB2="v${KERNELSUB}.x/"
      MANUAL="-menuconfig"

      print_info "Selected kernel" "$KERNELVER"
      print_info "Current kernel" "$CURVER"
      show_kernel_target "$KERNELVER"
      echo "Update kernel? [yes/NO]"
      read -r choice

      case "$choice" in
        yes)
          echo "Retrieving and installing selected kernel"
          install_kernel_minusk
          config_kernel_minusk
          ;;
        *)
          echo "please keep an eye on security issues in kernel updates."
          exit 0
          ;;
      esac
    else
      list_available_kernels
      exit 0
    fi
    ;;
esac

init_cpu_type
require_root
require_cmds

case "${1:-}" in
  -t|-T)
    KERNELVER="${2:-}"
    if [ -z "$KERNELVER" ]; then
      echo "Missing kernel tree version, example: -t 6.12"
      exit 1
    fi
    if [[ ! "$KERNELVER" =~ ^[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid kernel tree version: $KERNELVER"
      exit 1
    fi

    ONLINEVER="$(curl -ks https://www.kernel.org/finger_banner | grep -w "$KERNELVER" | cut -d ':' -f 2 | sed -n 1p | sed 's/ //g')"
    if [ -z "$ONLINEVER" ]; then
      echo "Could not resolve latest kernel on tree ${KERNELVER}."
      exit 1
    fi

    KERNELSUB="$(echo "$KERNELVER" | cut -f1 -d'.')"
    KERNELSUB2="v${KERNELSUB}.x/"
    MANUAL="-menuconfig"

    print_info "Kernel tree" "$KERNELVER"
    print_info "Latest kernel" "$ONLINEVER"
    print_info "Current kernel" "$CURVER"
    show_kernel_target "$ONLINEVER"
    echo "Update kernel? [yes/NO]"
    read -r choice

    case "$choice" in
      yes)
        echo "Retrieving and installing new kernel"
        install_kernel
        config_kernel
        ;;
      *)
        echo "please keep an eye on security issues in kernel updates."
        exit 0
        ;;
    esac
    ;;

  -k|-K)
    KERNELVER="${2:-}"
    if [ -z "$KERNELVER" ]; then
      echo "Missing kernel version, example: -k 6.12.90"
      exit 1
    fi
    if [[ ! "$KERNELVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid kernel version: $KERNELVER"
      exit 1
    fi

    ONLINEVER="$KERNELVER"
    KERNELSUB="$(echo "$KERNELVER" | cut -f1 -d'.')"
    KERNELSUB2="v${KERNELSUB}.x/"
    MANUAL="-menuconfig"

    print_info "Selected kernel" "$KERNELVER"
    print_info "Current kernel" "$CURVER"
    show_kernel_target "$KERNELVER"
    echo "Update kernel? [yes/NO]"
    read -r choice

    case "$choice" in
      yes)
        echo "Retrieving and installing selected kernel"
        install_kernel_minusk
        config_kernel_minusk
        ;;
      *)
        echo "please keep an eye on security issues in kernel updates."
        exit 0
        ;;
    esac
    ;;

  -h|-H|--help)
    show_usage
    ;;

  -m|-M)
    CURVER3="$(uname -r)"
    CURVER="$(uname -r | cut -f1 -d- | cut -f1-2 -d.)"
    CURVER2="$(uname -r | cut -f1 -d-)"

    ONLINEVER="$CURVER2"
    KERNELVER="$ONLINEVER"

    KERNELSUB="$(echo "$ONLINEVER" | cut -f1 -d'.')"
    KERNELSUB2="v${KERNELSUB}.x/"
    MANUAL="-menuconfig"

    print_info "Current kernel" "$CURVER3"
    print_info "Kernel source version" "$ONLINEVER"
    show_kernel_target "$ONLINEVER"

    SRCDIR="$(kernel_srcdir "$ONLINEVER")"

    if [ ! -d "$SRCDIR" ]; then
      echo "kernel source not found: ${SRCDIR}"
      echo "retrieving and extracting kernel source...."
      install_kernel
    fi

    SRCDIR="$(kernel_srcdir "$ONLINEVER")"

    if [ ! -d "$SRCDIR" ]; then
      echo "Kernel source still missing after download: ${SRCDIR}"
      exit 1
    fi

    if ! copy_latest_boot_config "$SRCDIR"; then
      echo "Missing boot config: /boot/config-${CURVER3}"
      echo "Also checked: /boot/config-${CURVER2:-} and newest /boot/config-*"
      exit 1
    fi

    cd "$SRCDIR"

    echo "reconfig old config file"
    make olddefconfig

    config_kernel2 "$1"
    ;;

  "")
    CURVER="$(uname -r | cut -f1 -d- | cut -f1-2 -d.)"
    CURVER2="$(uname -r | cut -f1 -d-)"

    ONLINEVER="$(curl -ks https://www.kernel.org/finger_banner | grep "${CURVER} version" | awk -v FS=' ' '{print $11}' | sed -n 1p)"
    ONLINEVERTREE="$(curl -ks https://www.kernel.org/finger_banner | grep "${CURVER} version" | awk -v FS=' ' '{print $4}' | sed -n 1p)"

    if [ -z "$ONLINEVER" ]; then
      echo "Could not determine latest kernel version for current tree ${CURVER}."
      exit 1
    fi

    KERNELSUB="$(echo "$ONLINEVER" | cut -f1 -d'.')"
    KERNELSUB2="v${KERNELSUB}.x/"
    KERNELVER="$ONLINEVER"

    if [ "${CPU_EXPLICIT:-0}" = "1" ]; then
      MANUAL="-menuconfig"
    fi

    echo "Checking current kernel version"
    print_info "Kernel tree" "$ONLINEVERTREE"
    print_info "Latest kernel" "$ONLINEVER"
    print_info "Current kernel" "$CURVER2"
    show_kernel_target "$ONLINEVER"

    if [ "$ONLINEVER" != "$CURVER2" ] || { [ "${CPU_EXPLICIT:-0}" = "1" ] && [ ! -f "$(kernel_srcdir "$ONLINEVER")/.config" ]; }; then
      echo "Update kernel? [yes/NO]"
      read -r choice

      case "$choice" in
        yes)
          echo "Retrieving and installing new kernel"
          install_kernel
          config_kernel
          if command -v update_issue.sh >/dev/null 2>&1; then
            update_issue.sh
          else
            echo "Warning: update_issue.sh not found, skipping."
          fi
          ;;
        *)
          echo "please keep an eye on security issues in kernel updates."
          exit 0
          ;;
      esac
    else
      echo "there is currently no need to update the kernel."
      exit 0
    fi
    ;;

  *)
    echo "Invalid option: ${1}"
    echo
    show_usage
    exit 1
    ;;
esac
