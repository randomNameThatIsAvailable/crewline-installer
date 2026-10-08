#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
# Fetch only an explicitly approved immutable public installer revision.
revision="${1:-}"
expected_sha256="${2:-}"
[[ $# == 2 && "$revision" =~ ^[0-9a-f]{40}$ && "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Usage: entry.sh APPROVED_COMMIT_SHA INSTALL_SH_SHA256" >&2; exit 1;
}
[[ "$(id -u)" == 0 && -t 0 && -t 1 ]] || { echo "Run as root in an interactive SSH terminal." >&2; exit 1; }
for executable in curl sha256sum mktemp; do command -v "$executable" >/dev/null || exit 1; done
temporary_directory="$(mktemp -d /tmp/crewline-entry.XXXXXX)"
cleanup() { rm -rf -- "$temporary_directory"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --connect-timeout 10 --max-time 120 --output "$temporary_directory/install.sh" "https://raw.githubusercontent.com/randomNameThatIsAvailable/crewline-installer/$revision/install.sh"
printf '%s  %s\n' "$expected_sha256" "$temporary_directory/install.sh" | sha256sum --check --strict --status
# The installer retains stdin/stdout and never runs through a pipe.
bash "$temporary_directory/install.sh"
