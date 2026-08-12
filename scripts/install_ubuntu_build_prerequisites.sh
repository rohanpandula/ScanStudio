#!/usr/bin/env bash
set -euo pipefail

# Release/preview Linux packages must not change merely because an Ubuntu
# mirror advanced between two runs.  This timestamped Ubuntu snapshot is an
# immutable, archive-signed resolution boundary for every apt input below.
readonly SNAPSHOT_STAMP="20260811T000000Z"
readonly SNAPSHOT_BASE="https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT_STAMP}"

if [[ "$(uname -s)" != "Linux" ]] || [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  echo "Pinned Ubuntu prerequisites require Linux amd64" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]] || [[ "${VERSION_ID:-}" != "22.04" ]]; then
  echo "Pinned Ubuntu prerequisites require Ubuntu 22.04" >&2
  exit 1
fi

task_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/scanstudio-ubuntu-snapshot.XXXXXX")"
readonly task_root
readonly sources_file="${task_root}/sources.list"
readonly apt_lists="${task_root}/apt-lists"
readonly apt_archives="${task_root}/apt-archives"
mkdir -p "${apt_lists}/partial" "${apt_archives}/partial"
chmod 0755 "${task_root}" "${apt_lists}" "${apt_lists}/partial" \
  "${apt_archives}" "${apt_archives}/partial"

cat >"${sources_file}" <<EOF
deb [check-valid-until=no signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] ${SNAPSHOT_BASE} jammy main restricted universe multiverse
deb [check-valid-until=no signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] ${SNAPSHOT_BASE} jammy-updates main restricted universe multiverse
deb [check-valid-until=no signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] ${SNAPSHOT_BASE} jammy-security main restricted universe multiverse
deb [check-valid-until=no signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] ${SNAPSHOT_BASE} jammy-backports main restricted universe multiverse
EOF

readonly expected_inrelease_hashes="${task_root}/expected-inrelease-hashes"
cat >"${expected_inrelease_hashes}" <<'EOF'
57600aafd922b5b4fd99f6cf3246ccd4f8cf61d5b1caccec6eec1ad2fe8abe23
98c8715a56c88b08479728c388fdc9854cfd6473e208fb18d75505e3dafc30c7
c14060cd8c6d625874dfcb9523a35a395bf4865c28b6b6a82569ef326fe92dc6
dd1338c7614fc1d0cf40e310ef2d1a8a88c7659e13d46420e5040abdd53e1148
EOF

apt_options=(
  -o "Dir::Etc::sourcelist=${sources_file}"
  -o "Dir::Etc::sourceparts=-"
  -o "Dir::State::lists=${apt_lists}"
  -o "Dir::Cache::archives=${apt_archives}"
  -o "Acquire::Check-Valid-Until=false"
  -o "Acquire::Retries=3"
  -o "Acquire::http::Timeout=30"
  -o "Acquire::https::Timeout=30"
)

if [[ "$(id -u)" -eq 0 ]]; then
  apt_command=(apt-get)
else
  apt_command=(sudo apt-get)
fi

verify_consumed_inrelease() {
  local actual_hashes="${task_root}/actual-inrelease-hashes"
  mapfile -t inrelease_files < <(
    find "${apt_lists}" -maxdepth 1 -type f -name '*_InRelease' -print | LC_ALL=C sort
  )
  if [[ "${#inrelease_files[@]}" -ne 4 ]]; then
    echo "Expected exactly four apt InRelease files, got ${#inrelease_files[@]}" >&2
    return 1
  fi
  sha256sum "${inrelease_files[@]}" | awk '{print $1}' | LC_ALL=C sort >"${actual_hashes}"
  cmp "${expected_inrelease_hashes}" "${actual_hashes}"
}

# The immutable Ubuntu base image intentionally does not ship a CA bundle.
# Bootstrap HTTPS using archive-signed metadata with peer validation disabled,
# prove those exact InRelease bytes, then install CA/Python and immediately
# discard/re-fetch all indexes with normal HTTPS peer verification enabled.
"${apt_command[@]}" "${apt_options[@]}" \
  -o "Acquire::https::Verify-Peer=false" update
verify_consumed_inrelease
"${apt_command[@]}" "${apt_options[@]}" \
  -o "Acquire::https::Verify-Peer=false" install -y --no-install-recommends \
  --allow-downgrades --reinstall ca-certificates curl python3
find "${apt_lists}" -mindepth 1 -maxdepth 1 -type f -delete
"${apt_command[@]}" "${apt_options[@]}" update
verify_consumed_inrelease

"${apt_command[@]}" "${apt_options[@]}" install -y --no-install-recommends \
  --allow-downgrades --reinstall \
  build-essential ca-certificates curl file libayatana-appindicator3-dev libfuse2 libgtk-3-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libunwind-dev librsvg2-dev \
  libsane-dev libssl-dev libusb-1.0-0 libwebkit2gtk-4.1-dev squashfs-tools \
  libxdo-dev patchelf pkg-config python3 sane-utils wget

echo "Ubuntu build prerequisites installed from ${SNAPSHOT_BASE}"
readonly installed_manifest="${task_root}/installed-dpkg-manifest.tsv"
dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort >"${installed_manifest}"
cat "${installed_manifest}"
sha256sum "${installed_manifest}"
