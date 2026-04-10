#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT_DIR}/android-stack.env"
DRY_RUN="false"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

usage() {
  cat <<'EOF'
Usage: sync-android-stack.sh [--config PATH] [--dry-run]
  --config PATH  Path to android-stack.env
  --dry-run      Print planned updates without modifying files
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      shift
      [ "$#" -gt 0 ] || { printf 'Missing value for --config\n'; usage; exit 1; }
      CONFIG_FILE="$1"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1"
      usage
      exit 1
      ;;
  esac
done

[ -f "$CONFIG_FILE" ] || { printf 'Config not found: %s\n' "$CONFIG_FILE"; exit 1; }

# shellcheck disable=SC1090
source "$CONFIG_FILE"

run_or_print() {
  if [ "$DRY_RUN" = "true" ]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    eval "$@"
  fi
}

update_wrapper() {
  local wrapper_file="$1"
  local url="distributionUrl=https\\://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-${GRADLE_DIST}.zip"

  if [ ! -f "$wrapper_file" ]; then
    return 0
  fi

  log "Updating wrapper: $wrapper_file"
  run_or_print "perl -0pi -e 's#^distributionUrl=.*#${url}#m' \"$wrapper_file\""
}

update_settings_groovy() {
  local settings_file="$1"

  [ -f "$settings_file" ] || return 0

  log "Updating settings: $settings_file"
  run_or_print "perl -0pi -e 's/id \"com\\.android\\.application\" version \"[^\"]+\" apply false/id \"com.android.application\" version \"${AGP_VERSION}\" apply false/g' \"$settings_file\""

  if grep -q 'id "org.jetbrains.kotlin.android"' "$settings_file"; then
    run_or_print "perl -0pi -e 's/id \"org\\.jetbrains\\.kotlin\\.android\" version \"[^\"]+\" apply false/id \"org.jetbrains.kotlin.android\" version \"${KOTLIN_VERSION}\" apply false/g' \"$settings_file\""
  fi

  return 0
}

update_settings_kts() {
  local settings_file="$1"

  [ -f "$settings_file" ] || return 0

  log "Updating settings: $settings_file"
  run_or_print "perl -0pi -e 's/id\\(\"com\\.android\\.application\"\\) version \"[^\"]+\" apply false/id(\"com.android.application\") version \"${AGP_VERSION}\" apply false/g' \"$settings_file\""
  run_or_print "perl -0pi -e 's/id\\(\"org\\.jetbrains\\.kotlin\\.android\"\\) version \"[^\"]+\" apply false/id(\"org.jetbrains.kotlin.android\") version \"${KOTLIN_VERSION}\" apply false/g' \"$settings_file\""

  return 0
}

update_legacy_kotlin_buildscript() {
  local build_file="$1"

  [ -f "$build_file" ] || return 0

  if ! grep -q "ext.kotlin_version" "$build_file"; then
    return 0
  fi

  log "Updating legacy Kotlin buildscript: $build_file"
  run_or_print "perl -0pi -e \"s/ext\\.kotlin_version = '[^']+'/ext.kotlin_version = '${KOTLIN_VERSION}'/g\" \"$build_file\""

  return 0
}

for project_dir in "${PROJECTS[@]}"; do
  [ -d "$project_dir" ] || { log "Skipping missing project: $project_dir"; continue; }

  android_dir="${project_dir}/android"
  [ -d "$android_dir" ] || { log "Skipping missing android dir: $android_dir"; continue; }

  update_wrapper "${android_dir}/gradle/wrapper/gradle-wrapper.properties"
  update_settings_groovy "${android_dir}/settings.gradle"
  update_settings_kts "${android_dir}/settings.gradle.kts"
  update_legacy_kotlin_buildscript "${android_dir}/build.gradle"
done

log "Done."
