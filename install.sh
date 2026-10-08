#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

repository="randomNameThatIsAvailable/crewline"
github_username="randomNameThatIsAvailable"
configuration_directory="/root/.config/crewline"
repository_token_file="$configuration_directory/github-token"
package_token_file="$configuration_directory/ghcr-token"
project_directory="/opt/crewline"
crewline_domain="ceremlin.mirrorcloudcenter.com"
bootstrap_directory="$configuration_directory/bootstrap"
pin_directory="$bootstrap_directory/release-pin"
recovery_directory="$bootstrap_directory"
resuming=false

# Bootstrap owns this lock; private deployment scripts retain their separate lock.
if [[ "$(id -u)" != 0 || ! -t 0 || ! -t 1 || -z "${SSH_CONNECTION:-}" ]]; then
    echo "Run as root over your existing SSH key login, with an interactive terminal." >&2
    exit 1
fi
[[ -s /root/.ssh/authorized_keys ]] || { echo "Install your root SSH public key before bootstrap." >&2; exit 1; }
command -v flock >/dev/null || { echo "Install util-linux before bootstrap." >&2; exit 1; }
[[ ! -L /run/crewline-bootstrap.lock && ( ! -e /run/crewline-bootstrap.lock || -f /run/crewline-bootstrap.lock ) ]] || exit 1
exec 8>>/run/crewline-bootstrap.lock
flock --nonblock 8 || { echo "Another bootstrap is running." >&2; exit 1; }
for directory in "$configuration_directory" "$bootstrap_directory" "$project_directory"; do
    [[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] || { echo "Unsafe bootstrap directory: $directory" >&2; exit 1; }
done
if [[ -e "$bootstrap_directory/owner" || -L "$bootstrap_directory/owner" ]]; then
    [[ ! -L "$bootstrap_directory/owner" && -f "$bootstrap_directory/owner" && "$(stat -c '%u:%a' "$bootstrap_directory/owner")" == 0:600 ]] || exit 1
    [[ "$(<"$bootstrap_directory/owner")" == crewline-bootstrap-v1 ]] || exit 1
    resuming=true
fi
if [[ -e "$pin_directory" || -L "$pin_directory" ]]; then
    [[ "$resuming" == true && ! -L "$pin_directory" && -d "$pin_directory" && "$(stat -c '%u:%a' "$pin_directory")" == 0:700 ]] || exit 1
    recovery_directory="$pin_directory"
    for name in release.env target archive.sha256; do
        [[ -f "$pin_directory/$name" ]] || { echo "Incomplete recovery pin; recover the state before continuing." >&2; exit 1; }
    done
fi
for name in release.env target archive.sha256 installer.sha256 firewall-owner; do
    for directory in "$bootstrap_directory" "$recovery_directory"; do
        path="$directory/$name"
        if [[ -e "$path" || -L "$path" ]]; then
            [[ ! -L "$path" && -f "$path" && "$(stat -c '%u:%a' "$path")" == 0:600 ]] || { echo "Unsafe bootstrap state: $path" >&2; exit 1; }
        fi
    done
done

temporary_directory=""
nginx_site_changed=false
nginx_site_existed=false
nginx_pending=""

cleanup() {
    if [[ "$nginx_site_changed" == true ]]; then
        if [[ "$nginx_site_existed" == true ]]; then
            cp -p -- "$temporary_directory/prior-site" "$nginx_pending" && mv -T -- "$nginx_pending" "$site"
        else
            rm -f -- "$site"
        fi
        nginx -t && systemctl reload nginx || true
    fi
    if [[ -n "$nginx_pending" ]]; then rm -f -- "$nginx_pending"; fi
    if [[ -n "${temporary_directory:-}" ]] \
        && [[ "$temporary_directory" == /tmp/crewline-install.* ]] \
        && [[ -d "$temporary_directory" ]]
    then
        rm -rf -- "$temporary_directory"
    fi
}

failure() {
    local line_number="$1"

    printf '\nCrewline installation stopped at line %s.\n' \
        "$line_number" >&2
    printf '%s\n' \
        "Existing Crewline data was not automatically deleted." >&2
}

trap 'failure "$LINENO"' ERR
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this installer as root." >&2
    exit 1
fi

if [[ ! -t 0 ]]; then
    echo "Crewline installation requires an interactive terminal." >&2
    echo "Download the approved entry script to a file, then run it from your SSH terminal." >&2
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "Could not identify the operating system." >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    echo "This installer currently supports Debian only." >&2
    exit 1
fi

if [[ "${VERSION_ID:-}" != "13" ]]; then
    printf 'Unsupported Debian version: %s\n' \
        "${VERSION_ID:-unknown}" >&2
    echo "Crewline currently requires Debian 13." >&2
    exit 1
fi

architecture="$(dpkg --print-architecture)"

if [[ "$architecture" != "amd64" ]]; then
    printf 'Unsupported architecture: %s\n' "$architecture" >&2
    echo "Crewline currently requires Debian amd64." >&2
    exit 1
fi

existing_installation_reasons=()

if [[ -e "$project_directory/.env" ]] \
    || [[ -L "$project_directory/.env" ]]
then
    existing_installation_reasons+=(
        "$project_directory/.env exists"
    )
fi

if [[ -d "$project_directory" ]] \
    && [[ -n "$(
        find \
            "$project_directory" \
            -mindepth 1 \
            -maxdepth 1 \
            -print \
            -quit
    )" ]]
then
    existing_installation_reasons+=(
        "$project_directory is not empty"
    )
fi

if command -v docker >/dev/null 2>&1; then
    if docker volume inspect \
        crewline_database_data \
        >/dev/null 2>&1
    then
        existing_installation_reasons+=(
            "Docker volume crewline_database_data exists"
        )
    fi

    if docker ps \
        --all \
        --quiet \
        --filter "label=com.docker.compose.project=crewline" |
        grep --quiet .
    then
        existing_installation_reasons+=(
            "Crewline Docker containers exist"
        )
    fi
fi

if (( ${#existing_installation_reasons[@]} > 0 )) && [[ "$resuming" != true ]]; then
    echo "An existing Crewline installation was detected:" >&2

    printf '  - %s\n' \
        "${existing_installation_reasons[@]}" >&2

    echo >&2
    echo "This bootstrap installer only performs clean installations." >&2
    echo "Use the existing Crewline update procedure instead:" >&2
    echo "  bash /opt/crewline/update-from-github.sh" >&2
    exit 1
fi

install -d -m 0700 "$configuration_directory" "$bootstrap_directory"
if [[ "$resuming" != true ]]; then
    owner_pending="$(mktemp "$bootstrap_directory/owner.XXXXXX")"
    printf '%s\n' crewline-bootstrap-v1 >"$owner_pending"
    mv -T -- "$owner_pending" "$bootstrap_directory/owner"
fi
# Pin the installer content too; changing recovery logic requires explicit intervention.
installer_sha256="$(sha256sum -- "${BASH_SOURCE[0]}" | cut -d ' ' -f 1)"
if [[ -f "$bootstrap_directory/installer.sha256" ]]; then
    [[ "$(<"$bootstrap_directory/installer.sha256")" == "$installer_sha256" ]] || { echo "Installer revision differs from the bootstrap owner; use the original approved installer." >&2; exit 1; }
else
    installer_pending="$(mktemp "$bootstrap_directory/installer.XXXXXX")"
    printf '%s\n' "$installer_sha256" >"$installer_pending"
    mv -T -- "$installer_pending" "$bootstrap_directory/installer.sha256"
fi
# Checkpoints are working notes, not evidence: required operations run on resume.
checkpoint() {
    local pending
    pending="$(mktemp "$bootstrap_directory/progress.XXXXXX")"
    printf '%s\n' "$1" >"$pending"
    mv -T -- "$pending" "$bootstrap_directory/progress"
}

echo "Protecting the host before installing application services..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends ufw ca-certificates curl python3 openssl
if systemctl is-active --quiet nftables || systemctl is-active --quiet firewalld; then
    echo "Another firewall manager is active; do not combine it with this UFW bootstrap." >&2
    exit 1
fi
[[ "$(/usr/sbin/sshd -T | awk '$1 == "pubkeyauthentication" {print $2}')" == yes ]] || exit 1
read -r ssh_client _ _ ssh_port <<<"$SSH_CONNECTION"
[[ "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1 && "$ssh_port" -le 65535 ]] || exit 1
mapfile -t ssh_ports < <(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}')
[[ "${#ssh_ports[@]}" -gt 0 ]] || exit 1
[[ ! -L "$bootstrap_directory/firewall-owner" ]] || exit 1
if [[ ! -f "$bootstrap_directory/firewall-owner" ]] && ufw status | grep -q '^Status: active'; then
    echo "An unmanaged UFW policy is already active; review it before bootstrap." >&2; exit 1
fi
if [[ -f "$bootstrap_directory/firewall-owner" ]]; then
    [[ "$(<"$bootstrap_directory/firewall-owner")" == crewline-ufw-v1 ]] || exit 1
else
    firewall_pending="$(mktemp "$bootstrap_directory/firewall.XXXXXX")"
    printf '%s\n' crewline-ufw-v1 >"$firewall_pending"
    mv -T -- "$firewall_pending" "$bootstrap_directory/firewall-owner"
fi
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
grep -qx 'IPV6=yes' /etc/default/ufw
# Retain both configured listeners and the effective port of the live SSH session.
for port in "${ssh_ports[@]}" "$ssh_port"; do ufw allow "$port/tcp" comment 'Crewline SSH'; done
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw --force enable
ufw status | grep -q '^Status: active'
checkpoint host-protected

echo "Installing required Debian packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install \
    --yes \
    --no-install-recommends \
    ca-certificates \
    curl \
    openssl \
    python3 \
    tar \
    util-linux \
    nginx \
    certbot

install_docker() {
    if command -v docker >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1
    then
        echo "Docker Engine and Docker Compose are already available."
        return
    fi

    conflicting_packages=()

    for package in \
        docker.io \
        docker-compose \
        docker-doc \
        docker-buildx \
        podman-docker \
        containerd \
        runc
    do
        if dpkg-query \
            --show \
            --showformat='${db:Status-Status}' \
            "$package" 2>/dev/null |
            grep --quiet '^installed$'
        then
            conflicting_packages+=("$package")
        fi
    done

    if [[ "${#conflicting_packages[@]}" -gt 0 ]]; then
        echo "Conflicting Docker packages are installed:" >&2

        printf '  %s\n' \
            "${conflicting_packages[@]}" >&2

        echo "Crewline will not automatically remove existing Docker packages." >&2
        echo "Resolve the Docker installation before retrying." >&2
        exit 1
    fi

    echo "Installing Docker Engine from Docker's official repository..."

    install -d -m 0755 /etc/apt/keyrings

    docker_key_temporary="$(
        mktemp /etc/apt/keyrings/docker.asc.XXXXXX
    )"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --output "$docker_key_temporary" \
        https://download.docker.com/linux/debian/gpg

    chmod 0644 "$docker_key_temporary"

    mv \
        --force \
        "$docker_key_temporary" \
        /etc/apt/keyrings/docker.asc

    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update

    apt-get install \
        --yes \
        --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker
}

install_docker

docker compose version
docker info >/dev/null

install -d \
    -m 0700 \
    -o root \
    -g root \
    "$configuration_directory"

temporary_directory="$(
    mktemp -d /tmp/crewline-install.XXXXXX
)"

repository_metadata="$temporary_directory/repository.json"
release_metadata="$temporary_directory/releases.json"
release_selection="$temporary_directory/release-selection.txt"
authentication_config="$temporary_directory/github-auth.conf"

validate_token_file() {
    local path="$1"
    local description="$2"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 1
    fi

    if [[ -L "$path" || ! -f "$path" ]]; then
        printf '%s must be a regular file: %s\n' \
            "$description" \
            "$path" >&2
        exit 1
    fi

    token_metadata="$(
        stat \
            --format '%u:%a' \
            "$path"
    )"

    if [[ "$token_metadata" != "0:600" ]]; then
        printf '%s must be owned by root with permissions 0600: %s\n' \
            "$description" \
            "$path" >&2
        exit 1
    fi

    if [[ ! -s "$path" ]]; then
        printf '%s is empty: %s\n' \
            "$description" \
            "$path" >&2
        return 1
    fi

    return 0
}

write_token_file() {
    local path="$1"
    local token="$2"

    temporary_token="$(
        mktemp "$configuration_directory/token.XXXXXX"
    )"

    chmod 0600 "$temporary_token"
    printf '%s' "$token" >"$temporary_token"

    chown root:root "$temporary_token"
    chmod 0600 "$temporary_token"

    mv \
        --force \
        "$temporary_token" \
        "$path"
}

write_authentication_config() {
    local token="$1"
    [[ "$token" =~ ^[A-Za-z0-9_]+$ ]] || { echo "Invalid token characters." >&2; return 1; }

    printf 'header = "Authorization: Bearer %s"\n' \
        "$token" >"$authentication_config"

    chmod 0600 "$authentication_config"
}

validate_repository_token() {
    local token="$1"

    write_authentication_config "$token"

    status="$(
        curl \
            --config "$authentication_config" \
            --silent \
            --show-error \
            --output "$repository_metadata" \
            --write-out '%{http_code}' \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            --connect-timeout 10 \
            --max-time 60 \
            "https://api.github.com/repos/$repository"
    )"

    if [[ "$status" != "200" ]]; then
        printf 'GitHub repository access failed with HTTP %s.\n' \
            "$status" >&2
        return 1
    fi

    python3 \
        - "$repository_metadata" "$repository" <<'PY'
import json
import pathlib
import sys

metadata_path = pathlib.Path(sys.argv[1])
expected_repository = sys.argv[2]

with metadata_path.open(
    "r",
    encoding="utf-8",
) as stream:
    metadata = json.load(stream)

if metadata.get("full_name") != expected_repository:
    raise SystemExit(
        "The token returned an unexpected repository."
    )

if metadata.get("private") is not True:
    raise SystemExit(
        "The Crewline application repository was expected "
        "to be private."
    )

print(
    "Repository token validated for:",
    metadata["full_name"],
)
PY
}

show_repository_token_guide() {
    cat <<'EOF'

Crewline requires read-only access to its private GitHub repository.

Create a fine-grained personal access token:

1. Open:
   https://github.com/settings/personal-access-tokens/new

2. Token name:
   Crewline VPS repository reader

3. Resource owner:
   Select the GitHub account that owns Crewline.

4. Repository access:
   Select "Only select repositories".

5. Selected repository:
   crewline

6. Repository permissions:
   Contents: Read-only

7. Metadata:
   GitHub adds read-only Metadata access automatically.

8. Create the token, copy it, and paste it below.

Do not grant write access.
Do not grant Actions, Administration, Secrets, or Workflows access.

The token will be stored at:
  /root/.config/crewline/github-token

The file will be owned by root with permissions 0600.

EOF
}

obtain_repository_token() {
    repository_token=""

    if validate_token_file \
        "$repository_token_file" \
        "GitHub repository token"
    then
        repository_token="$(
            tr -d '\r\n' <"$repository_token_file"
        )"

        if validate_repository_token "$repository_token"; then
            return
        fi

        echo "The stored repository token is no longer valid." >&2
    fi

    show_repository_token_guide

    while true; do
        read \
            -r \
            -s \
            -p "Fine-grained GitHub repository token: " \
            repository_token

        printf '\n'

        repository_token="$(
            printf '%s' "$repository_token" |
                tr -d '\r\n'
        )"

        if [[ -z "$repository_token" ]]; then
            echo "The token must not be empty." >&2
            continue
        fi

        if validate_repository_token "$repository_token"; then
            write_token_file \
                "$repository_token_file" \
                "$repository_token"

            echo "Repository token saved securely."
            return
        fi

        echo "The token could not access the private Crewline repository." >&2
        echo "Review the instructions and try again." >&2
    done
}

show_package_token_guide() {
    cat <<'EOF'

Crewline requires read-only access to its private container images.

GitHub Packages currently requires a personal access token (classic).

Create the package token:

1. Open:
   https://github.com/settings/tokens/new?scopes=read:packages

2. Note:
   Crewline VPS GHCR reader

3. Select only:
   read:packages

4. Do not select:
   write:packages
   delete:packages

5. Create the token, copy it, and paste it below.

The token will be stored at:
  /root/.config/crewline/ghcr-token

The file will be owned by root with permissions 0600.
Docker also stores its authenticated registry configuration under:
  /root/.docker/config.json

EOF
}

validate_package_token() {
    local token="$1"
    [[ "$token" =~ ^[A-Za-z0-9_]+$ ]] || return 1

    if printf '%s' "$token" |
        docker login \
            ghcr.io \
            --username "$github_username" \
            --password-stdin
    then
        return
    fi

    return 1
}

obtain_package_token() {
    package_token=""

    if validate_token_file \
        "$package_token_file" \
        "GHCR package token"
    then
        package_token="$(
            tr -d '\r\n' <"$package_token_file"
        )"

        if validate_package_token "$package_token"; then
            echo "Stored GHCR package token validated."
            return
        fi

        echo "The stored GHCR package token is no longer valid." >&2
    fi

    show_package_token_guide

    while true; do
        read \
            -r \
            -s \
            -p "Classic GitHub read:packages token: " \
            package_token

        printf '\n'

        package_token="$(
            printf '%s' "$package_token" |
                tr -d '\r\n'
        )"

        if [[ -z "$package_token" ]]; then
            echo "The token must not be empty." >&2
            continue
        fi

        if validate_package_token "$package_token"; then
            write_token_file \
                "$package_token_file" \
                "$package_token"

            echo "GHCR package token saved securely."
            return
        fi

        echo "GHCR authentication failed." >&2
        echo "Confirm that the classic token has read:packages." >&2
    done
}

obtain_repository_token
obtain_package_token

domain="$crewline_domain"

write_authentication_config "$repository_token"

echo "Reading published Crewline releases..."

curl \
    --config "$authentication_config" \
    --fail \
    --silent \
    --show-error \
    --location \
    --connect-timeout 10 \
    --max-time 120 \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --output "$release_metadata" \
    "https://api.github.com/repos/$repository/releases?per_page=100"

download_asset() {
    curl --config "$authentication_config" --fail --silent --show-error --location --connect-timeout 10 --max-time 600 --header 'Accept: application/octet-stream' --header 'X-GitHub-Api-Version: 2022-11-28' --output "$2" "$1"
}
python3 - "$release_metadata" >"$release_selection" <<'PY'
import json, re, sys
from pathlib import Path
candidates = []
for release in json.loads(Path(sys.argv[1]).read_text()):
    tag = release.get("tag_name", "")
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-rc\.(\d+))?", tag)
    if release.get("draft") or not match or not isinstance(release.get("id"), int):
        continue
    major, minor, patch, rc = match.groups()
    candidates.append(((int(major), int(minor), int(patch), rc is None, int(rc or 0)), release["id"], tag))
for _, release_id, tag in sorted(candidates, reverse=True):
    print(f"{release_id}|{tag}")
PY
release_tag=""
# Once selected, the release is frozen for recovery, even if a newer one appears.
if [[ -f "$recovery_directory/release.env" ]]; then
    release_tag="$(sed -n 's/^CREWLINE_RELEASE=//p' "$recovery_directory/release.env")"
    [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || exit 1
    curl --config "$authentication_config" --fail --silent --show-error --connect-timeout 10 --max-time 120 --header 'Accept: application/vnd.github+json' --output "$temporary_directory/pinned-release.json" "https://api.github.com/repos/$repository/releases/tags/$release_tag"
    candidate_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$temporary_directory/pinned-release.json")"
    printf '%s|%s\n' "$candidate_id" "$release_tag" >"$release_selection"
    release_tag=""
fi
while IFS='|' read -r candidate_id candidate_tag; do
    assets_path="$temporary_directory/assets-$candidate_id.json"
    curl --config "$authentication_config" --fail --silent --show-error --location --connect-timeout 10 --max-time 120 --header 'Accept: application/vnd.github+json' --header 'X-GitHub-Api-Version: 2022-11-28' --output "$assets_path" "https://api.github.com/repos/$repository/releases/$candidate_id/assets?per_page=100"
    mapfile -t asset_urls < <(python3 - "$assets_path" "$candidate_tag" <<'PY'
import json, sys
from pathlib import Path
assets = {asset.get("name"): asset.get("url") for asset in json.loads(Path(sys.argv[1]).read_text()) if asset.get("state") == "uploaded"}
archive = f"crewline-{sys.argv[2]}.tar.gz"
names = (archive, archive + ".sha256", "release.env")
if all(assets.get(name) for name in names):
    for name in names:
        print(assets[name])
PY
    )
    [[ "${#asset_urls[@]}" -eq 3 ]] || continue
    manifest_path="$temporary_directory/release.env"
    download_asset "${asset_urls[2]}" "$manifest_path"
    if python3 - "$manifest_path" "$candidate_tag" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
if path.stat().st_size > 16384:
    raise SystemExit(1)
values = {}
for line in path.read_text().splitlines():
    if not line or line.startswith("#"):
        continue
    key, separator, value = line.partition("=")
    if not separator or key in values or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
        raise SystemExit(1)
    values[key] = value
if values.get("CREWLINE_DEPLOYMENT_CONTRACT") != "host-nginx-http-v1" or values.get("CREWLINE_RELEASE") != sys.argv[2]:
    raise SystemExit(1)
if values.get("CREWLINE_BOOTSTRAP_CONTRACT") != "resume-v1":
    raise SystemExit(1)
for key in ("CREWLINE_BACKEND_IMAGE", "CREWLINE_FRONTEND_IMAGE"):
    if not re.fullmatch(r"ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}", values.get(key, "")):
        raise SystemExit(1)
PY
    then
        release_tag="$candidate_tag"
        archive_url="${asset_urls[0]}"
        checksum_url="${asset_urls[1]}"
        break
    fi
done <"$release_selection"
[[ -n "$release_tag" ]] || { echo "No complete host-nginx-http-v1 / resume-v1 release is published. Publish the Slice 2 Crewline source first." >&2; exit 1; }
expected_target="$(printf '%s\n' "domain=$crewline_domain" 'gateway=127.0.0.1:18080' 'http=80' 'https=443' 'panel=127.0.0.1:2053' 'tailscale_https=9443')"
if [[ -f "$recovery_directory/release.env" ]]; then
    cmp --silent "$manifest_path" "$recovery_directory/release.env" || { echo "Pinned release manifest changed; recovery stopped without altering the installation." >&2; exit 1; }
    [[ -f "$recovery_directory/target" ]] || { echo "Missing bootstrap target; recover the state rather than guessing." >&2; exit 1; }
fi
if [[ -f "$recovery_directory/target" ]]; then
    [[ "$(<"$recovery_directory/target")" == "$expected_target" ]] || { echo "Bootstrap target differs from this installer revision." >&2; exit 1; }
fi
archive_name="crewline-$release_tag.tar.gz"
checksum_name="$archive_name.sha256"
archive_path="$temporary_directory/$archive_name"
checksum_path="$temporary_directory/$checksum_name"
echo "Selected compatible Crewline release: $release_tag"

echo "Downloading $archive_name..."
download_asset "$archive_url" "$archive_path"

echo "Downloading $checksum_name..."
download_asset "$checksum_url" "$checksum_path"
if [[ -f "$recovery_directory/archive.sha256" ]]; then
    cmp --silent "$checksum_path" "$recovery_directory/archive.sha256" || { echo "Pinned archive checksum changed; recovery stopped." >&2; exit 1; }
fi

(
    cd -- "$temporary_directory"
    python3 - "$checksum_name" "$archive_name" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="ascii")
if not re.fullmatch(r"[0-9a-fA-F]{64} [ *]" + re.escape(sys.argv[2]) + r"(?:\r?\n)?", text):
    raise SystemExit("Expected exactly one checksum for the selected archive.")
PY
    sha256sum --check --strict "$checksum_name"
)

python3 - "$archive_path" <<'PY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])

with tarfile.open(archive, "r:gz") as bundle:
    names = set()
    for member in bundle.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if (
            path.is_absolute() or ".." in path.parts or "\\" in member.name
            or not path.parts or path.as_posix() in names
            or not (member.isfile() or member.isdir())
            or path.parts[0] in {".env", "certificates", "private_media", "staticfiles"}
            or path.parts[0].startswith(".crewline")
        ):
            raise SystemExit(f"Unsafe or protected archive member: {member.name}")
        names.add(path.as_posix())

print("Release archive paths are safe.")
PY

staging="$temporary_directory/release"

install -d -m 0700 "$staging"

tar \
    --extract \
    --gzip \
    --file "$archive_path" \
    --directory "$staging" \
    --no-same-owner

for required_file in \
    compose.yaml \
    release.env \
    install.sh \
    update.sh \
    deploy.sh \
    rollback.sh \
    apply-release.sh \
    update-from-github.sh \
    ops/crewlinectl \
    docker/configure_environment.py
do
    if [[ ! -f "$staging/$required_file" ]]; then
        printf 'Release is missing required file: %s\n' \
            "$required_file" >&2
        exit 1
    fi
done

python3 -B "$staging/docker/deployment_contract.py" archive "$archive_path" --tag "$release_tag" --manifest "$manifest_path"

# Commit all recovery inputs together only after checksum and archive validation.
# An interrupted pending directory is never used as authoritative recovery state.
if [[ ! -d "$pin_directory" ]]; then
    pending_pin="$(mktemp -d "$bootstrap_directory/release-pin.pending.XXXXXX")"
    install -m 0600 "$manifest_path" "$pending_pin/release.env"
    install -m 0600 "$checksum_path" "$pending_pin/archive.sha256"
    printf '%s\n' "$expected_target" >"$pending_pin/target"
    mv -T -- "$pending_pin" "$pin_directory"
fi
checkpoint release-selected

install -d \
    -m 0750 \
    -o root \
    -g root \
    "$project_directory"

# Hold the deployment lock during copying and the private installer invocation.
[[ ! -L "$project_directory/.crewline-deploy.lock" && ( ! -e "$project_directory/.crewline-deploy.lock" || -f "$project_directory/.crewline-deploy.lock" ) ]] || exit 1
exec 9>>"$project_directory/.crewline-deploy.lock"
flock --nonblock 9 || { echo "Another Crewline deployment is running." >&2; exit 1; }
deployment_record="$project_directory/.crewline-deployment/current.env"
if [[ -e "$deployment_record" || -L "$deployment_record" ]]; then
    [[ ! -L "$project_directory/.crewline-deployment" && ! -L "$deployment_record" && -f "$deployment_record" ]] || exit 1
    cmp --silent "$manifest_path" "$deployment_record" || { echo "Crewline has a different deployed release; use the update procedure instead of bootstrap recovery." >&2; exit 1; }
fi
cp -a \
    "$staging"/. \
    "$project_directory"/

chown -R root:root "$project_directory"

chmod 0750 \
    "$project_directory/install.sh" \
    "$project_directory/update.sh" \
    "$project_directory/deploy.sh" \
    "$project_directory/rollback.sh" \
    "$project_directory/apply-release.sh" \
    "$project_directory/update-from-github.sh" \
    "$project_directory/enable-https.sh" \
    "$project_directory/ops/crewlinectl"

echo
echo "Installing Crewline $release_tag..."

bash \
    "$project_directory/install.sh" \
    "$domain" --resume --bootstrap-lock-held
exec 9>&-
checkpoint application-ready

echo "Configuring host nginx and obtaining the HTTPS certificate..."
site=/etc/nginx/conf.d/crewline.conf
[[ ! -L "$site" && ( ! -e "$site" || -f "$site" ) ]] || exit 1
if [[ -f "$site" ]] && ! head -n 1 "$site" | grep -qx '# Crewline managed host-nginx-http-v1'; then
    echo "Existing nginx site is not Crewline-managed; review it before replacement." >&2
    exit 1
fi
getent ahostsv4 "$domain" >/dev/null || { echo "Create the public IPv4 DNS record for $domain, then rerun." >&2; exit 1; }
certificate="/etc/letsencrypt/live/$domain/fullchain.pem"
private_key="/etc/letsencrypt/live/$domain/privkey.pem"
if [[ ! -f "$certificate" ]] || ! openssl x509 -in "$certificate" -noout -checkend 86400 >/dev/null; then
    install -d -m 0755 /var/www/crewline-acme
    cat >"$temporary_directory/http.conf" <<EOF
# Crewline managed host-nginx-http-v1
server {
    listen 80;
    server_name $domain;
    location /.well-known/acme-challenge/ { root /var/www/crewline-acme; }
    location / { return 503; }
}
EOF
    # Keep the prior site available for recovery if candidate validation fails.
    if [[ -f "$site" ]]; then cp -p -- "$site" "$temporary_directory/prior-site"; nginx_site_existed=true; fi
    nginx_pending="$(mktemp /etc/nginx/conf.d/.crewline-http.XXXXXX)"
    install -m 0644 "$temporary_directory/http.conf" "$nginx_pending"
    nginx_site_changed=true
    mv -T -- "$nginx_pending" "$site"
    nginx -t
    ufw allow 80/tcp comment 'Crewline HTTP and ACME'
    systemctl enable --now nginx
    systemctl reload nginx
    # Certbot handles account consent interactively; no invented email or silent ToS consent.
    certbot certonly --webroot --webroot-path /var/www/crewline-acme --cert-name "$domain" --domain "$domain" --preferred-challenges http
fi
ufw allow 80/tcp comment 'Crewline HTTP and ACME'
ufw allow 443/tcp comment 'Crewline HTTPS'
systemctl enable --now nginx
bash "$project_directory/enable-https.sh" "$domain" "$certificate" "$private_key"
nginx_site_changed=false
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
hook=/etc/letsencrypt/renewal-hooks/deploy/crewline-nginx
[[ ! -L "$hook" && ( ! -e "$hook" || -f "$hook" ) ]] || exit 1
if [[ -f "$hook" ]] && ! grep -q '^# Crewline managed renewal hook$' "$hook"; then
    echo "Refusing to overwrite an unmanaged certificate renewal hook." >&2; exit 1
fi
printf '%s\n' '#!/bin/sh' '# Crewline managed renewal hook' 'nginx -t && systemctl reload nginx' >"$temporary_directory/renewal-hook"
hook_pending="$(mktemp /etc/letsencrypt/renewal-hooks/deploy/.crewline-nginx.XXXXXX)"
install -m 0750 "$temporary_directory/renewal-hook" "$hook_pending"
mv -T -- "$hook_pending" "$hook"
systemctl enable --now certbot.timer
checkpoint crewline-https-ready

# Slice 3 is deliberately inline: the pinned entry verifies this entire installer.
echo "Installing private Tailscale / 3x-ui access..."
ufw status | grep -q '^Status: active'
private_helper="$temporary_directory/private-access.py"
cat >"$private_helper" <<'PY'
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import sqlite3
import stat
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "v3.9.0"
COMMIT = "3cd4bf504c3cd8ea9b1c1fdb032a9796c5c43ddb"
ARCHIVE_SHA256 = "d7cbe0bf6358ee0d2117c24fd2efb483502e411d38e2ea59bd0bf5e7a3e39390"
INSTALLER_SHA256 = "18616fe26c8f6c92db6daa2dcd7cd53c5143ee69ecfd26d8ea6dc9b2c78607a6"
STATE = Path("/root/.config/crewline/bootstrap/private-access")
PANEL = Path("/usr/local/x-ui")
DATABASE = Path("/etc/x-ui/x-ui.db")
UNIT = Path("/etc/systemd/system/x-ui.service")
PIN = {"version": VERSION, "commit": COMMIT, "archive_sha256": ARCHIVE_SHA256,
       "installer_sha256": INSTALLER_SHA256, "panel": "127.0.0.1:2053", "serve_port": 9443}


def require_regular(path, mode=0o600):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) != mode:
        raise ValueError("Expected a root-owned protected regular file: " + str(path))


def safe_directory(path):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise ValueError("Unsafe private-access directory: " + str(path))
    if path.exists() and path.stat().st_uid != 0:
        raise ValueError("Private-access directory is not root-owned: " + str(path))


def state():
    safe_directory(STATE)
    if not STATE.exists() or stat.S_IMODE(STATE.stat().st_mode) != 0o700:
        raise ValueError("Missing or unsafe private-access ownership state.")
    require_regular(STATE / "pin.json")
    if json.loads((STATE / "pin.json").read_text()) != PIN:
        raise ValueError("Private-access recovery target changed.")
    require_regular(STATE / "initial-panel.json")
    credentials = json.loads((STATE / "initial-panel.json").read_text())
    if not re.fullmatch(r"[0-9a-f]{24}", credentials.get("username", "")) or not re.fullmatch(r"[0-9a-f]{64}", credentials.get("password", "")) or not re.fullmatch(r"/[0-9a-f]{48}/", credentials.get("base_path", "")):
        raise ValueError("Invalid retained initial panel credentials.")
    return credentials


def initialize_state():
    if STATE.exists() or STATE.is_symlink():
        state()
        return
    # A bootstrap marker elsewhere does not authorize takeover of an existing panel.
    paths = (PANEL, DATABASE.parent, UNIT, Path("/lib/systemd/system/x-ui.service"),
             Path("/usr/lib/systemd/system/x-ui.service"), Path("/etc/default/x-ui"))
    fragment = subprocess.run(["systemctl", "show", "--property=FragmentPath", "--value", "x-ui.service"],
                              capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    if any(path.exists() or path.is_symlink() for path in paths) or shutil.which("x-ui") or fragment:
        raise ValueError("Unowned 3x-ui installation found; private bootstrap stopped.")
    pending = Path(tempfile.mkdtemp(prefix="private-access.pending.", dir=STATE.parent))
    credentials = {"username": secrets.token_hex(12), "password": secrets.token_hex(32),
                   "base_path": "/" + secrets.token_hex(24) + "/"}
    for name, values in (("pin.json", PIN), ("initial-panel.json", credentials)):
        path = pending / name
        with path.open("x") as stream:
            os.chmod(path, 0o600)
            json.dump(values, stream)
            stream.flush()
            os.fsync(stream.fileno())
    os.rename(pending, STATE)


def install_archive(archive):
    state()
    safe_directory(PANEL)
    marker = PANEL / ".crewline-bootstrap-pin.json"
    if PANEL.exists():
        require_regular(marker)
        installed = json.loads(marker.read_text())
        if installed.get("pin") != PIN or set(installed.get("binaries", {})) != {"x-ui", "bin/xray-linux-amd64"}:
            raise ValueError("Installed panel is not owned by this recovery pin.")
        for name, digest in installed["binaries"].items():
            require_regular(PANEL / name, 0o750)
            with (PANEL / name).open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
                    raise ValueError("Installed panel binary changed; bootstrap recovery stopped.")
        return
    with Path(archive).open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != ARCHIVE_SHA256:
            raise ValueError("Pinned 3x-ui archive checksum mismatch.")
    pending = Path(tempfile.mkdtemp(prefix=".crewline-x-ui.pending.", dir=PANEL.parent))
    with tarfile.open(archive, "r:gz") as bundle:
        names = set()
        for member in bundle.getmembers():
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or "\\" in member.name or
                not path.parts or path.parts[0] != "x-ui" or path.as_posix() in names or
                not (member.isfile() or member.isdir()) or any(part.startswith(".crewline") for part in path.parts)):
                raise ValueError("Unsafe 3x-ui archive member.")
            names.add(path.as_posix())
        for name in ("x-ui/x-ui", "x-ui/bin/xray-linux-amd64"):
            if name not in names or not bundle.getmember(name).isfile():
                raise ValueError("Pinned panel archive is missing required binaries.")
        bundle.extractall(pending, filter="data")
    root = pending / "x-ui"
    os.chmod(root, 0o750)
    for binary in (root / "x-ui", root / "bin/xray-linux-amd64"):
        os.chmod(binary, 0o750)
    marker = root / ".crewline-bootstrap-pin.json"
    binaries = {}
    for name in ("x-ui", "bin/xray-linux-amd64"):
        with (root / name).open("rb") as stream:
            binaries[name] = hashlib.file_digest(stream, "sha256").hexdigest()
    marker.write_text(json.dumps({"pin": PIN, "binaries": binaries}))
    os.chmod(marker, 0o600)
    os.rename(root, PANEL)
    pending.rmdir()


def configure_database(work):
    import bcrypt
    credentials = state()
    safe_directory(DATABASE.parent)
    if Path("/etc/default/x-ui").exists() or Path("/etc/default/x-ui").is_symlink():
        raise ValueError("Unexpected upstream panel environment file; review it before recovery.")
    DATABASE.parent.mkdir(mode=0o700, exist_ok=True)
    fresh = not DATABASE.exists() and not DATABASE.is_symlink()
    path = DATABASE
    if fresh:
        staging = Path(work) / "panel-database"
        staging.mkdir(mode=0o700)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("XUI_")}
        environment.update(XUI_DB_FOLDER=str(staging), XUI_DB_TYPE="sqlite", XUI_BIN_FOLDER=str(PANEL / "bin"))
        subprocess.run([str(PANEL / "x-ui"), "migrate"], env=environment, cwd=PANEL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=120)
        path = staging / "x-ui.db"
        os.chmod(path, 0o600)
    require_regular(path)
    with sqlite3.connect(path) as database:
        if database.execute("SELECT count(*) FROM inbounds").fetchone()[0]:
            raise ValueError("Panel has existing VPN inbounds; bootstrap will not reinterpret them.")
        if fresh:
            users = database.execute("SELECT id FROM users").fetchall()
            if len(users) != 1:
                raise ValueError("Unexpected fresh panel user schema.")
            database.execute("UPDATE users SET username=?, password=? WHERE id=?",
                             (credentials["username"], bcrypt.hashpw(credentials["password"].encode(), bcrypt.gensalt()).decode(), users[0][0]))
        else:
            users = database.execute("SELECT username,password FROM users").fetchall()
            if not users or any(not username or not password or bcrypt.checkpw(b"admin", password.encode()) for username, password in users):
                raise ValueError("Panel credentials are empty/default; recovery will not expose or reset them.")
        settings = {"webListen": "127.0.0.1", "webPort": "2053", "webCertFile": "", "webKeyFile": "",
                    "subEnable": "false", "subJsonEnable": "false", "subClashEnable": "false",
                    "subListen": "127.0.0.1", "subPort": "2096"}
        if fresh:
            settings["webBasePath"] = credentials["base_path"]
        else:
            rows = database.execute("SELECT value FROM settings WHERE key='webBasePath'").fetchall()
            if len(rows) != 1 or not re.fullmatch(r"/[A-Za-z0-9_-]{4,128}/", rows[0][0]):
                raise ValueError("Existing panel base path needs manual review; it was not reset.")
        for key, value in settings.items():
            rows = database.execute("SELECT id FROM settings WHERE key=?", (key,)).fetchall()
            if len(rows) > 1:
                raise ValueError("Duplicate panel setting; recovery stopped.")
            if rows:
                database.execute("UPDATE settings SET value=? WHERE key=?", (value, key))
            else:
                database.execute("INSERT INTO settings (key,value) VALUES (?,?)", (key, value))
        database.commit()
        if fresh:
            descriptor, pending_name = tempfile.mkstemp(prefix=".crewline-db.pending.", dir=DATABASE.parent)
            os.close(descriptor)
            try:
                with sqlite3.connect(pending_name) as target:
                    database.backup(target)
                os.chmod(pending_name, 0o600)
                os.link(pending_name, DATABASE)
            finally:
                Path(pending_name).unlink(missing_ok=True)


def probe_panel(url=None):
    state()
    require_regular(DATABASE)
    with sqlite3.connect(DATABASE) as database:
        rows = database.execute("SELECT value FROM settings WHERE key='webBasePath'").fetchall()
        if len(rows) != 1 or not re.fullmatch(r"/[A-Za-z0-9_-]{4,128}/", rows[0][0]):
            raise ValueError("Unsafe panel path; probe stopped.")
        path = rows[0][0]
    target = (url or "http://127.0.0.1:2053") + path
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(target, timeout=10) as response:
        if response.status != 200:
            raise ValueError("Panel HTTP probe did not succeed.")
    if url is not None:
        access = STATE / "current-access.json"
        if access.exists() or access.is_symlink():
            require_regular(access)
        descriptor, pending_name = tempfile.mkstemp(prefix="access.pending.", dir=STATE)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump({"https_origin": url, "base_path": path}, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(pending_name, access)
        finally:
            Path(pending_name).unlink(missing_ok=True)


def serve_config(mode, before, after=None):
    original = json.loads(Path(before).read_text()) or {}
    current = (json.loads(Path(after).read_text()) or {}) if after else original
    for config in (original, current):
        for foreground in (config.get("Foreground") or {}).values():
            if "9443" in (foreground.get("TCP") or {}):
                raise ValueError("Port 9443 is owned by a foreground Serve session.")
        if any(value for key, value in (config.get("AllowFunnel") or {}).items() if key.endswith(":9443")):
            raise ValueError("Port 9443 allows public Funnel access; private bootstrap stopped.")
        tcp = (config.get("TCP") or {}).get("9443")
        web = {key: value for key, value in (config.get("Web") or {}).items() if key.endswith(":9443")}
        if tcp is not None or web:
            if tcp != {"HTTPS": True} or len(web) != 1 or next(iter(web.values())) != {"Handlers": {"/": {"Proxy": "http://127.0.0.1:2053"}}}:
                raise ValueError("Port 9443 has a conflicting Serve configuration.")
        elif mode == "after" and config is current:
            raise ValueError("Persistent private Serve configuration is missing.")
    if after:
        def unrelated(config):
            result = copy.deepcopy(config)
            for field in ("TCP", "Web", "AllowFunnel"):
                values = result.get(field) or {}
                result[field] = {key: value for key, value in values.items() if key != "9443" and not key.endswith(":9443")}
            return result
        if unrelated(original) != unrelated(current):
            raise ValueError("Unrelated Tailscale Serve configuration changed; review before continuing.")


parser = argparse.ArgumentParser()
parser.add_argument("command", choices=("initialize", "archive", "database", "probe", "serve-before", "serve-after"))
parser.add_argument("arguments", nargs="*")
arguments = parser.parse_args()
try:
    if arguments.command == "initialize": initialize_state()
    elif arguments.command == "archive": install_archive(arguments.arguments[0])
    elif arguments.command == "database": configure_database(arguments.arguments[0])
    elif arguments.command == "probe": probe_panel(*arguments.arguments)
    elif arguments.command == "serve-before": serve_config("before", *arguments.arguments)
    else: serve_config("after", *arguments.arguments)
except ValueError as error:
    parser.exit(1, str(error) + " Retained credentials were not reset.\n")
except (OSError, sqlite3.Error, tarfile.TarError, subprocess.SubprocessError):
    parser.exit(1, "Private-access " + arguments.command + " failed; retained credentials were not reset. Review the protected files and retry the same approved revision.\n")
PY

python3 -B "$private_helper" initialize
if ! command -v tailscale >/dev/null 2>&1; then
    curl --proto '=https' --fail --silent --show-error --connect-timeout 10 --max-time 120 --output "$temporary_directory/tailscale.gpg" https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg
    curl --proto '=https' --fail --silent --show-error --connect-timeout 10 --max-time 120 --output "$temporary_directory/tailscale.list" https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list
    install -d -m 0755 /usr/share/keyrings
    for item in 'tailscale.gpg|/usr/share/keyrings/tailscale-archive-keyring.gpg' 'tailscale.list|/etc/apt/sources.list.d/tailscale.list'; do
        IFS='|' read -r candidate_name destination <<<"$item"
        [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || exit 1
        if [[ -f "$destination" ]]; then
            cmp --silent "$temporary_directory/$candidate_name" "$destination" || { echo "Existing Tailscale package configuration differs; review it before recovery." >&2; exit 1; }
        else
            package_pending="$(mktemp "$(dirname -- "$destination")/.crewline-tailscale.XXXXXX")"
            install -m 0644 "$temporary_directory/$candidate_name" "$package_pending"
            mv -T -- "$package_pending" "$destination"
        fi
    done
    apt-get update
    apt-get install --yes --no-install-recommends tailscale
fi
apt-get install --yes --no-install-recommends python3-bcrypt
systemctl enable --now tailscaled
tailscale status --json >"$temporary_directory/tailscale-status.json"
if ! python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("BackendState") != "Running")' "$temporary_directory/tailscale-status.json"; then
    echo "Authenticate this VPS to your tailnet using the URL from Tailscale (180-second limit)."
    if ! timeout --foreground 180 tailscale up --timeout=170s; then
        echo "Tailscale authentication is pending. Complete it, then rerun this approved installer; Crewline HTTPS remains configured." >&2
        exit 1
    fi
fi
tailscale status --json >"$temporary_directory/tailscale-status.json"
tailnet_host="$(python3 - "$temporary_directory/tailscale-status.json" <<'PY'
import json, re, sys
from pathlib import Path
status = json.loads(Path(sys.argv[1]).read_text())
name = (status.get("Self") or {}).get("DNSName", "").rstrip(".")
if status.get("BackendState") != "Running" or not re.fullmatch(r"[a-z0-9.-]+\.ts\.net", name):
    raise SystemExit("Tailscale login or tailnet DNS is pending; rerun after completing it.")
print(name)
PY
)"
checkpoint tailscale-authenticated

# Capture configuration before changing only the private 9443 listener.
tailscale serve status --json >"$temporary_directory/serve-before.json"
python3 -B "$private_helper" serve-before "$temporary_directory/serve-before.json"
if [[ ! -d /usr/local/x-ui ]]; then
    curl --proto '=https' --fail --silent --show-error --location --connect-timeout 10 --max-time 600 --output "$temporary_directory/x-ui.tar.gz" https://github.com/MHSanaei/3x-ui/releases/download/v3.9.0/x-ui-linux-amd64.tar.gz
    python3 -B "$private_helper" archive "$temporary_directory/x-ui.tar.gz"
else
    python3 -B "$private_helper" archive "$temporary_directory/x-ui.tar.gz"
fi
panel_unit=/etc/systemd/system/x-ui.service
[[ ! -L "$panel_unit" && ( ! -e "$panel_unit" || -f "$panel_unit" ) ]] || exit 1
if [[ -f "$panel_unit" ]] && ! head -n 1 "$panel_unit" | grep -qx '# Crewline managed private 3x-ui v1'; then
    echo "Refusing to replace an unmanaged x-ui.service." >&2; exit 1
fi
panel_fragment="$(systemctl show --property=FragmentPath --value x-ui.service)"
panel_dropins="$(systemctl show --property=DropInPaths --value x-ui.service)"
[[ ( -z "$panel_fragment" || "$panel_fragment" == "$panel_unit" ) && -z "$panel_dropins" ]] || { echo "Unexpected x-ui service override; review it before recovery." >&2; exit 1; }
systemctl stop x-ui.service 2>/dev/null || { [[ ! -e "$panel_unit" ]] || exit 1; }
python3 -B "$private_helper" database "$temporary_directory"
cat >"$temporary_directory/x-ui.service" <<'UNIT'
# Crewline managed private 3x-ui v1
[Unit]
Description=Crewline private 3x-ui panel
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/x-ui
Environment=XUI_DB_FOLDER=/etc/x-ui
Environment=XUI_DB_TYPE=sqlite
Environment=XUI_BIN_FOLDER=/usr/local/x-ui/bin
ExecStart=/usr/local/x-ui/x-ui run
UMask=0077
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
panel_unit_pending="$(mktemp /etc/systemd/system/.crewline-x-ui.XXXXXX)"
install -m 0644 "$temporary_directory/x-ui.service" "$panel_unit_pending"
mv -T -- "$panel_unit_pending" "$panel_unit"
systemctl daemon-reload
systemctl enable --now x-ui.service
panel_ready=false
for attempt in {1..15}; do
    if python3 -B "$private_helper" probe 2>/dev/null; then panel_ready=true; break; fi
    sleep 2
done
[[ "$panel_ready" == true ]] || { echo "Private panel startup remains unverified; recovery state was retained." >&2; exit 1; }
ss -H -lntp 'sport = :2053' >"$temporary_directory/panel-listeners.txt"
panel_pid="$(systemctl show --property=MainPID --value x-ui.service)"
python3 - "$temporary_directory/panel-listeners.txt" "$panel_pid" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
pid = int(sys.argv[2])
if pid <= 0 or not lines or any(line.split()[3] != "127.0.0.1:2053" or f"pid={pid}," not in line for line in lines):
    raise SystemExit("Panel listener is not owned by the managed service on IPv4 loopback.")
PY
if [[ -n "$(ss -H -lnt 'sport = :2096')" ]]; then
    echo "A subscription listener is active on 2096; private bootstrap stopped." >&2; exit 1
fi
checkpoint private-panel-ready
echo "Initial panel credentials and base path: $bootstrap_directory/private-access/initial-panel.json (root-only; values are not printed)."
echo "Tailnet HTTPS may need enabling in the Tailscale admin console; Serve confirmation has a 180-second limit."
if ! timeout --foreground 180 tailscale serve --bg --https=9443 http://127.0.0.1:2053; then
    echo "Private HTTPS setup is pending. Enable tailnet HTTPS if required, then rerun this approved installer. The panel remains on loopback." >&2
    exit 1
fi
tailscale serve status --json >"$temporary_directory/serve-after.json"
python3 -B "$private_helper" serve-after "$temporary_directory/serve-before.json" "$temporary_directory/serve-after.json"
python3 -B "$private_helper" probe "https://$tailnet_host:9443"
for unit in tailscaled x-ui.service; do
    systemctl is-active --quiet "$unit"
    systemctl is-enabled --quiet "$unit"
done
checkpoint private-access-ready

echo
echo "Crewline HTTPS and private panel bootstrap checks completed on this VPS."
echo "Installed release: $release_tag"
echo
echo "Crewline: https://$domain"
echo "Host nginx owns 80/443; the application gateway remains 127.0.0.1:18080."
echo "Recovery state: $bootstrap_directory (root-only). Rerun the same approved installer revision to resume."
echo "Private panel HTTPS origin: https://$tailnet_host:9443"
echo "Current panel base path/access record: $bootstrap_directory/private-access/current-access.json (root-only)."
echo "Verified here: loopback panel response, loopback-only 2053 listener, disabled 2096 listener, persistent Serve configuration and local tailnet HTTPS response."
echo "Not verified here: access from your phone/another tailnet device or the original external Crewline network problem."
echo "Replace the initial panel credentials, restrict tailnet access to this node/9443, and consider disabling this server's machine-key expiry."
echo "SSH-tunnel fallback: forward local port 2053 to VPS 127.0.0.1:2053; append the retained panel base path."
echo "Xray VPN transport and port 8443 remain deferred; no VPN inbound was created."
