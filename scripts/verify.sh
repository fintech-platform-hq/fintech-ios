#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DERIVED_DATA_PATH="${REPO_ROOT}/.build/DerivedData"
CURRENT_STEP="initialization"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  printf 'ERROR: Verification failed during: %s (exit %d, line %d)\n' \
    "${CURRENT_STEP}" "${exit_code}" "${BASH_LINENO[0]}" >&2
  exit "${exit_code}"
}

trap on_error ERR

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required."
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required."
command -v plutil >/dev/null 2>&1 || fail "plutil is required."

CURRENT_STEP="detecting the Xcode project"
project_path=""
project_count=0

while IFS= read -r candidate; do
  project_path="${candidate}"
  project_count=$((project_count + 1))
done < <(
  find "${REPO_ROOT}" -maxdepth 2 -type d -name '*.xcodeproj' \
    -exec test -f '{}/project.pbxproj' \; -print | sort
)

if [[ "${project_count}" -eq 0 ]]; then
  fail "No Xcode project containing project.pbxproj was found."
fi

if [[ "${project_count}" -ne 1 ]]; then
  fail "Expected one buildable Xcode project, found ${project_count}."
fi

CURRENT_STEP="detecting a shared or automatically generated scheme"
scheme="$(
  xcodebuild -project "${project_path}" -list -json |
    plutil -extract project.schemes.0 raw -o - -- -
)"

if [[ -z "${scheme}" ]]; then
  fail "No scheme was detected in ${project_path}."
fi

CURRENT_STEP="detecting an installed compatible iOS Simulator"
destinations="$(
  xcodebuild -project "${project_path}" -scheme "${scheme}" -showdestinations 2>&1
)"

simulator_id="$(
  printf '%s\n' "${destinations}" |
    awk '
      /platform:iOS Simulator/ && !/placeholder/ {
        value = $0
        sub(/^.*id:/, "", value)
        sub(/,.*/, "", value)
        gsub(/[[:space:]]/, "", value)
        if (value != "") {
          print value
          exit
        }
      }
    '
)"

if [[ -z "${simulator_id}" ]]; then
  printf '%s\n' "${destinations}" >&2
  fail "No installed iOS Simulator is compatible with scheme ${scheme}."
fi

destination="platform=iOS Simulator,id=${simulator_id}"
mkdir -p "${DERIVED_DATA_PATH}"

printf 'Project: %s\n' "${project_path}"
printf 'Scheme: %s\n' "${scheme}"
printf 'Destination: %s\n' "${destination}"
printf 'Derived data: %s\n' "${DERIVED_DATA_PATH}"

CURRENT_STEP="building ${scheme} for iOS Simulator"
xcodebuild \
  -project "${project_path}" \
  -scheme "${scheme}" \
  -configuration Debug \
  -destination "${destination}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

CURRENT_STEP="running the test targets configured in ${scheme}"
xcodebuild \
  -project "${project_path}" \
  -scheme "${scheme}" \
  -configuration Debug \
  -destination "${destination}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -parallel-testing-enabled NO \
  test

CURRENT_STEP="complete"
printf 'Verification passed: Simulator build and scheme tests succeeded.\n'
