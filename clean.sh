#!/usr/bin/env bash
# Dev machine disk cleanup script used for prior freespace steps.
# Run from Terminal with Full Disk Access enabled. Some steps need sudo.

set -euo pipefail

# Options
NO_BREW="false"
PROJECT_CLEAN="true"
PROJECT_MAX_DEPTH="5"
PROJECT_ROOTS=("$HOME/Documents")
PROJECT_ROOTS_SET="false"
AGGRESSIVE_CACHES="false"

# Paths that may or may not exist
XCODE_DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
XCODE_DEVICE_SUPPORT="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
XCODE_ARCHIVES="$HOME/Library/Developer/Xcode/Archives"
XCODE_LOGS="$HOME/Library/Developer/Xcode/Logs"
XCODE_DEVICE_LOGS="$HOME/Library/Developer/Xcode/iOS Device Logs"
SIM_DEVICES="$HOME/Library/Developer/CoreSimulator/Devices"
VS_CODE_SUPPORT="$HOME/Library/Application Support/Code"
CHROME_SUPPORT="$HOME/Library/Application Support/Google/Chrome"
ANDROID_SDK="$HOME/Library/Android/sdk"
ANDROID_AVD="$HOME/.android/avd"
GRADLE_CACHE="$HOME/.gradle"
USER_CACHE="$HOME/.cache"
SWIFTPM_CACHE="$HOME/Library/Caches/org.swift.swiftpm"
COCOAPODS_CACHE="$HOME/Library/Caches/CocoaPods"
CARTHAGE_CACHE="$HOME/Library/Caches/org.carthage.CarthageKit"
XCODE_CACHE="$HOME/Library/Caches/com.apple.dt.Xcode"
NPM_CACHE="$HOME/.npm"
YARN_CACHE="$HOME/.yarn/cache"
PNPM_STORE="$HOME/.pnpm-store"
PIP_CACHE="$HOME/Library/Caches/pip"
PUB_CACHE="$HOME/.pub-cache"
SIM_VOLUMES_DIR="/Library/Developer/CoreSimulator/Volumes"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

usage() {
  cat <<'EOF'
Usage: clean.sh [--no-brew] [--no-project-clean] [--aggressive-caches] [--project-root PATH] [--max-depth N]
  --no-brew   Skip Homebrew and CocoaPods cache cleanup
  --no-project-clean  Skip project artifact cleanup
  --aggressive-caches  Remove ~/Library/Caches/* (rebuilds app caches)
  --project-root PATH  Add a project root to scan (repeatable). Default: ~/Documents
  --max-depth N  Max folder depth to scan within project roots (default: 5)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-brew) NO_BREW="true"; shift ;;
    --no-project-clean) PROJECT_CLEAN="false"; shift ;;
    --aggressive-caches) AGGRESSIVE_CACHES="true"; shift ;;
    --project-root)
      shift
      [ "$#" -gt 0 ] || { printf 'Missing value for --project-root\n'; usage; exit 1; }
      if [ "$PROJECT_ROOTS_SET" = "false" ]; then
        PROJECT_ROOTS=()
        PROJECT_ROOTS_SET="true"
      fi
      PROJECT_ROOTS+=("$1")
      shift
      ;;
    --max-depth)
      shift
      [ "$#" -gt 0 ] || { printf 'Missing value for --max-depth\n'; usage; exit 1; }
      PROJECT_MAX_DEPTH="$1"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1"; usage; exit 1 ;;
  esac
done

version_key() {
  local v="$1"
  local digits key part
  digits=$(printf '%s' "$v" | tr -c '0-9' '.')
  key=""
  IFS='.' read -r -a parts <<< "$digits"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    key="${key}$(printf '%05d' "$part")"
  done
  [ -n "$key" ] || key="00000"
  printf '%s' "$key"
}

simctl_runtime_id_for_build() {
  local build="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$build" 2>/dev/null
import json, subprocess, sys
build = sys.argv[1]
try:
    out = subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"], text=True)
    data = json.loads(out)
    for rt in data.get("runtimes", []):
        b = rt.get("buildversion") or rt.get("buildVersion") or rt.get("build")
        if b == build:
            print(rt.get("identifier", ""))
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
    return
  fi
  xcrun simctl list runtimes 2>/dev/null | awk -v b="($build)" '
    index($0,b) {
      match($0,/com\.apple\.CoreSimulator\.SimRuntime\.[^ )]+/);
      if (RSTART) { print substr($0,RSTART,RLENGTH); exit }
    }'
}

delete_ios_runtime_by_build() {
  local build="$1"
  local runtime_id
  runtime_id=$(simctl_runtime_id_for_build "$build")
  if [ -z "$runtime_id" ]; then
    log "No simctl runtime id found for build $build; skipping."
    return 1
  fi
  if xcrun simctl runtime delete "$runtime_id" >/dev/null 2>&1; then
    log "Deleted runtime via simctl: $runtime_id"
    return 0
  fi
  log "simctl runtime delete failed for $runtime_id; skipping."
  return 1
}

PROJECT_PRUNE_ARGS=(
  -type d \( -name .git -o -name node_modules -o -name vendor -o -name build -o -name .dart_tool -o -name .gradle -o -name .cache -o -name Library -o -name Pods -o -name DerivedData -o -name .tox -o -name .nox -o -name .venv -o -name venv -o -name __pycache__ \) -prune -o
)

remove_dir() {
  local path="$1"
  if [ -e "$path" ]; then
    log "Removing $path"
    if ! rm -rf "$path" 2>/dev/null; then
      log "Failed to remove $path (permission or in-use). Skipping."
    fi
  fi
}

remove_dir_sudo() {
  local path="$1"
  if [ -e "$path" ]; then
    if [ -t 0 ]; then
      log "Removing (sudo) $path"
      sudo chflags -R nouchg,noschg "$path" || true
      if ! sudo rm -rf "$path"; then
        log "Failed to remove (sudo) $path. Skipping."
      fi
    else
      if sudo -n true 2>/dev/null; then
        log "Removing (sudo) $path"
        sudo -n chflags -R nouchg,noschg "$path" || true
        if ! sudo -n rm -rf "$path"; then
          log "Failed to remove (sudo) $path. Skipping."
        fi
      else
        log "Skipping (sudo) $path (no TTY for password)."
      fi
    fi
  fi
}

unmount_volume() {
  local vol="$1"
  if [ -d "$vol" ]; then
    log "Unmounting $vol"
    diskutil unmount "$vol" || {
      # Try forced unmount of the disk if needed
      local dev
      dev=$(diskutil list | awk -v v="$vol" '$0 ~ v {print $1; exit}')
      [ -n "$dev" ] && diskutil unmountDisk force "$dev" || true
    }
  fi
}

clean_project_artifacts() {
  if [ "$PROJECT_CLEAN" != "true" ]; then
    log "Skipping project artifact cleanup (--no-project-clean)"
    return
  fi
  if [ "${#PROJECT_ROOTS[@]}" -eq 0 ]; then
    log "No project roots configured; skipping project cleanup."
    return
  fi

  for root in "${PROJECT_ROOTS[@]}"; do
    if [ ! -d "$root" ]; then
      log "Project root not found: $root (skipping)"
      continue
    fi
    log "Scanning projects under $root (max depth $PROJECT_MAX_DEPTH)"

    while IFS= read -r -d '' pkg; do
      proj=$(dirname "$pkg")
      remove_dir "$proj/node_modules"
      if grep -q '"react"' "$pkg" 2>/dev/null; then
        remove_dir "$proj/build"
      fi
    done < <(find "$root" -maxdepth "$PROJECT_MAX_DEPTH" "${PROJECT_PRUNE_ARGS[@]}" -type f -name package.json -print0 2>/dev/null) || true

    while IFS= read -r -d '' pubspec; do
      if grep -q '^[[:space:]]*flutter:' "$pubspec" 2>/dev/null; then
        proj=$(dirname "$pubspec")
        remove_dir "$proj/build"
        remove_dir "$proj/.dart_tool"
      fi
    done < <(find "$root" -maxdepth "$PROJECT_MAX_DEPTH" "${PROJECT_PRUNE_ARGS[@]}" -type f -name pubspec.yaml -print0 2>/dev/null) || true

    while IFS= read -r -d '' composer; do
      proj=$(dirname "$composer")
      remove_dir "$proj/vendor"
    done < <(find "$root" -maxdepth "$PROJECT_MAX_DEPTH" "${PROJECT_PRUNE_ARGS[@]}" -type f -name composer.json -print0 2>/dev/null) || true

    while IFS= read -r -d '' pyproj; do
      proj=$(dirname "$pyproj")
      remove_dir "$proj/.pytest_cache"
      remove_dir "$proj/.mypy_cache"
      remove_dir "$proj/.ruff_cache"
      remove_dir "$proj/.hypothesis"
      remove_dir "$proj/.tox"
      remove_dir "$proj/.nox"
      remove_dir "$proj/.eggs"
      remove_dir "$proj/build"
      remove_dir "$proj/dist"
      while IFS= read -r -d '' egginfo; do
        remove_dir "$egginfo"
      done < <(find "$proj" -maxdepth 1 -type d -name "*.egg-info" -print0 2>/dev/null) || true
      while IFS= read -r -d '' cache; do
        remove_dir "$cache"
      done < <(find "$proj" -maxdepth "$PROJECT_MAX_DEPTH" -type d -name "__pycache__" -print0 2>/dev/null) || true
    done < <(find "$root" -maxdepth "$PROJECT_MAX_DEPTH" "${PROJECT_PRUNE_ARGS[@]}" -type f \( -name pyproject.toml -o -name setup.py -o -name setup.cfg -o -name requirements.txt \) -print0 2>/dev/null) || true
  done
}

clean_aggressive_caches() {
  if [ "$AGGRESSIVE_CACHES" != "true" ]; then
    log "Skipping aggressive cache cleanup (--aggressive-caches)"
    return
  fi
  if [ -d "$HOME/Library/Caches" ]; then
    log "Removing ~/Library/Caches/*"
    for p in "$HOME/Library/Caches"/*; do
      [ -e "$p" ] || continue
      remove_dir "$p"
    done
  fi
}

log "Stopping Simulator/Xcode services"
killall -9 Simulator Xcode 2>/dev/null || true
killall -9 com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true

log "Unmounting mounted simulator runtime volumes (safe to ignore failures)"
for mp in /Volumes/*Simulator; do
  [ -d "$mp" ] && unmount_volume "$mp"
done

log "Removing unavailable simulators via simctl"
xcrun simctl delete unavailable >/dev/null 2>&1 || true

log "Pruning iOS simulator runtimes (keep latest OS version)"
if [ -d "$SIM_VOLUMES_DIR" ]; then
  ios_vols=()
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    ios_vols+=("$d")
  done < <(ls -1 "$SIM_VOLUMES_DIR" 2>/dev/null | awk '/^iOS[ _]/ {print}')
  if [ "${#ios_vols[@]}" -gt 1 ]; then
    latest_vol=""
    latest_key=""
    for d in "${ios_vols[@]}"; do
      ver="${d#iOS }"
      ver="${ver#iOS_}"
      key=$(version_key "$ver")
      if [ -z "$latest_key" ] || [[ "$key" > "$latest_key" ]]; then
        latest_key="$key"
        latest_vol="$d"
      fi
    done
    if [ -n "$latest_vol" ]; then
      log "Keeping iOS runtime: $SIM_VOLUMES_DIR/$latest_vol"
      for d in "${ios_vols[@]}"; do
        [ "$d" = "$latest_vol" ] && continue
        build="${d#iOS }"
        build="${build#iOS_}"
        delete_ios_runtime_by_build "$build" || remove_dir_sudo "$SIM_VOLUMES_DIR/$d"
      done
    fi
  else
    log "Only one iOS runtime found; nothing to prune."
  fi
fi

log "Pruning iOS simulator devices (keep latest OS version)"
if [ -d "$SIM_DEVICES" ]; then
  device_dirs=()
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    device_dirs+=("$d")
  done < <(find "$SIM_DEVICES" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  if [ "${#device_dirs[@]}" -le 1 ]; then
    log "Only one simulator device found; nothing to prune."
  else
    device_rows=()
    versions=()
    for d in "${device_dirs[@]}"; do
      plist="$d/device.plist"
      [ -f "$plist" ] || continue
      runtime=$(plutil -p "$plist" 2>/dev/null | awk -F\" '/runtime/ {print $4; exit}')
      [ -n "$runtime" ] || continue
      case "$runtime" in
        *".iOS-"*|*"iOS-"*) ;;
        *) continue ;;
      esac
      version=$(printf '%s' "$runtime" | sed -E 's/.*iOS-//; s/-/./g')
      device_rows+=("$d|$version")
      versions+=("$version")
    done
    if [ "${#versions[@]}" -eq 0 ]; then
      log "No iOS simulator devices found to prune."
    else
      uniq_count=$(printf '%s\n' "${versions[@]}" | sort | uniq | wc -l | tr -d ' ')
      if [ "$uniq_count" -le 1 ]; then
        log "Only one iOS simulator OS version found; nothing to prune."
      else
        latest_ver=""
        latest_key=""
        for v in "${versions[@]}"; do
          key=$(version_key "$v")
          if [ -z "$latest_key" ] || [[ "$key" > "$latest_key" ]]; then
            latest_key="$key"
            latest_ver="$v"
          fi
        done
        log "Keeping iOS simulators for OS version $latest_ver"
        for row in "${device_rows[@]}"; do
          d="${row%%|*}"
          v="${row##*|}"
          if [ "$v" != "$latest_ver" ]; then
            remove_dir "$d"
          fi
        done
      fi
    fi
  fi
fi

log "Cleaning Xcode DerivedData/DeviceSupport"
remove_dir "$XCODE_DERIVED"
remove_dir "$XCODE_DEVICE_SUPPORT"
remove_dir "$XCODE_ARCHIVES"
remove_dir "$XCODE_LOGS"
remove_dir "$XCODE_DEVICE_LOGS"
remove_dir "$XCODE_CACHE"
remove_dir "$SWIFTPM_CACHE"
remove_dir "$COCOAPODS_CACHE"
remove_dir "$CARTHAGE_CACHE"

log "Cleaning VS Code caches"
remove_dir "$VS_CODE_SUPPORT/Cache"
remove_dir "$VS_CODE_SUPPORT/CachedData"
remove_dir "$VS_CODE_SUPPORT/CachedExtensionVSIXs"
remove_dir "$VS_CODE_SUPPORT/Service Worker"
remove_dir "$VS_CODE_SUPPORT/WebStorage"
remove_dir "$VS_CODE_SUPPORT/logs"
remove_dir "$VS_CODE_SUPPORT/Crashpad"
remove_dir "$VS_CODE_SUPPORT/GPUCache"

log "Removing Chrome OptGuideOnDeviceModel cache (large)"
remove_dir "$CHROME_SUPPORT/OptGuideOnDeviceModel"

log "Pruning Android emulators and system images (keep latest OS version)"
latest_android_ver=""
latest_android_key=""

if [ -d "$ANDROID_AVD" ]; then
  avd_dirs=()
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    avd_dirs+=("$d")
  done < <(find "$ANDROID_AVD" -mindepth 1 -maxdepth 1 -type d -name "*.avd" 2>/dev/null)
  if [ "${#avd_dirs[@]}" -le 1 ]; then
    log "Only one Android AVD found; nothing to prune."
  else
    avd_rows=()
    avd_versions=()
    for d in "${avd_dirs[@]}"; do
      cfg="$d/config.ini"
      [ -f "$cfg" ] || continue
      sysdir=$(awk -F= '/^image\.sysdir\.1=/ {print $2; exit}' "$cfg")
      if [ -n "$sysdir" ]; then
        api=$(printf '%s' "$sysdir" | sed -E 's#.*system-images/([^/]+)/.*#\1#')
      else
        target=$(awk -F= '/^target=/ {print $2; exit}' "$cfg")
        if [[ "$target" == android-* ]]; then
          api="$target"
        elif [ -n "$target" ]; then
          api="android-$(printf '%s' "$target" | awk -F: '{print $NF}')"
        else
          api=""
        fi
      fi
      [ -n "$api" ] || continue
      ver="${api#android-}"
      avd_rows+=("$d|$ver")
      avd_versions+=("$ver")
    done
    if [ "${#avd_versions[@]}" -eq 0 ]; then
      log "No Android AVDs with identifiable system images; skipping AVD prune."
    else
      uniq_count=$(printf '%s\n' "${avd_versions[@]}" | sort | uniq | wc -l | tr -d ' ')
      for v in "${avd_versions[@]}"; do
        key=$(version_key "$v")
        if [ -z "$latest_android_key" ] || [[ "$key" > "$latest_android_key" ]]; then
          latest_android_key="$key"
          latest_android_ver="$v"
        fi
      done
      if [ "$uniq_count" -le 1 ]; then
        log "Only one Android emulator OS version found; nothing to prune."
      else
        log "Keeping Android AVDs for OS version $latest_android_ver"
        for row in "${avd_rows[@]}"; do
          d="${row%%|*}"
          v="${row##*|}"
          if [ "$v" != "$latest_android_ver" ]; then
            remove_dir "$d"
            ini="${d%.avd}.ini"
            [ -e "$ini" ] && remove_dir "$ini"
          fi
        done
      fi
    fi
  fi
fi

if [ -d "$ANDROID_SDK/system-images" ]; then
  image_dirs=()
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    image_dirs+=("$d")
  done < <(find "$ANDROID_SDK/system-images" -mindepth 1 -maxdepth 1 -type d -name "android-*" -exec basename {} \; 2>/dev/null)
  if [ "${#image_dirs[@]}" -gt 1 ]; then
    if [ -z "$latest_android_ver" ]; then
      for d in "${image_dirs[@]}"; do
        ver="${d#android-}"
        key=$(version_key "$ver")
        if [ -z "$latest_android_key" ] || [[ "$key" > "$latest_android_key" ]]; then
          latest_android_key="$key"
          latest_android_ver="$ver"
        fi
      done
    fi
    keep_image="android-$latest_android_ver"
    match_found=false
    for d in "${image_dirs[@]}"; do
      if [ "$d" = "$keep_image" ]; then
        match_found=true
        break
      fi
    done
    if [ "$match_found" = true ]; then
      log "Keeping Android system image: $ANDROID_SDK/system-images/$keep_image"
      for d in "${image_dirs[@]}"; do
        [ "$d" = "$keep_image" ] && continue
        remove_dir "$ANDROID_SDK/system-images/$d"
      done
    else
      log "No system image matched latest Android OS version; skipping system image prune."
    fi
  else
    log "Only one Android system image found; nothing to prune."
  fi
fi

log "Pruning Android NDKs (keep latest two)"
if [ -d "$ANDROID_SDK/ndk" ]; then
  ndk_dirs=()
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    ndk_dirs+=("$d")
  done < <(find "$ANDROID_SDK/ndk" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)
  if [ "${#ndk_dirs[@]}" -gt 2 ]; then
    keep_a=""
    keep_b=""
    keep_a_key=""
    keep_b_key=""
    for d in "${ndk_dirs[@]}"; do
      key=$(version_key "$d")
      if [ -z "$keep_a_key" ] || [[ "$key" > "$keep_a_key" ]]; then
        keep_b="$keep_a"
        keep_b_key="$keep_a_key"
        keep_a="$d"
        keep_a_key="$key"
      elif [ -z "$keep_b_key" ] || [[ "$key" > "$keep_b_key" ]]; then
        keep_b="$d"
        keep_b_key="$key"
      fi
    done
    log "Keeping NDKs: $keep_a $keep_b"
    for d in "${ndk_dirs[@]}"; do
      if [ "$d" != "$keep_a" ] && [ "$d" != "$keep_b" ]; then
        remove_dir "$ANDROID_SDK/ndk/$d"
      fi
    done
  else
    log "NDK versions <=2; nothing to prune."
  fi
fi

log "Removing Gradle and user cache folders"
remove_dir "$GRADLE_CACHE"
remove_dir "$USER_CACHE"
remove_dir "$NPM_CACHE"
remove_dir "$YARN_CACHE"
remove_dir "$PNPM_STORE"
remove_dir "$PIP_CACHE"
remove_dir "$PUB_CACHE"

log "Cleaning additional user caches (optional)"
clean_aggressive_caches

log "Cleaning project artifacts (Flutter/React/Node/PHP/Python)"
clean_project_artifacts

if [ "$NO_BREW" = "true" ]; then
  log "Skipping Homebrew and CocoaPods cache cleanup (--no-brew)"
else
  log "Running Homebrew and CocoaPods cache cleanup"
  brew cleanup -s || true
  pod cache clean --all || true
fi

log "Done. Remaining simulator runtimes:"
ls -lh "$SIM_VOLUMES_DIR" || true
