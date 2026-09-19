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

temporary_directory=""

cleanup() {
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

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this installer as root." >&2
    exit 1
fi

if [[ ! -t 0 ]]; then
    echo "Crewline installation requires an interactive terminal." >&2
    echo "Use bash <(curl ...), not curl ... | bash." >&2
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

if (( ${#existing_installation_reasons[@]} > 0 )); then
    echo "An existing Crewline installation was detected:" >&2

    printf '  - %s\n' \
        "${existing_installation_reasons[@]}" >&2

    echo >&2
    echo "This bootstrap installer only performs clean installations." >&2
    echo "Use the existing Crewline update procedure instead:" >&2
    echo "  bash /opt/crewline/update-from-github.sh" >&2
    exit 1
fi

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
    util-linux

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

python3 \
    - "$release_metadata" >"$release_selection" <<'PY'
import json
import pathlib
import re
import sys

metadata_path = pathlib.Path(sys.argv[1])

with metadata_path.open(
    "r",
    encoding="utf-8",
) as stream:
    releases = json.load(stream)

tag_pattern = re.compile(
    r"^v[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[0-9]+)?$"
)

for release in releases:
    if release.get("draft"):
        continue

    tag = release.get("tag_name", "")

    if not tag_pattern.fullmatch(tag):
        continue

    archive_name = f"crewline-{tag}.tar.gz"
    checksum_name = f"{archive_name}.sha256"

    assets = {
        asset.get("name"): asset.get("url")
        for asset in release.get("assets", [])
    }

    archive_url = assets.get(archive_name)
    checksum_url = assets.get(checksum_name)

    if archive_url and checksum_url:
        print(tag)
        print(archive_url)
        print(checksum_url)
        break
else:
    raise SystemExit(
        "No complete published Crewline release was found. "
        "Stable releases and prereleases were both considered."
    )
PY

mapfile -t release_values <"$release_selection"

if [[ "${#release_values[@]}" -ne 3 ]]; then
    echo "GitHub returned an unexpected release selection." >&2
    exit 1
fi

release_tag="${release_values[0]}"
archive_url="${release_values[1]}"
checksum_url="${release_values[2]}"

archive_name="crewline-$release_tag.tar.gz"
checksum_name="$archive_name.sha256"
archive_path="$temporary_directory/$archive_name"
checksum_path="$temporary_directory/$checksum_name"

echo "Selected Crewline release: $release_tag"

download_asset() {
    local asset_url="$1"
    local destination="$2"

    curl \
        --config "$authentication_config" \
        --fail \
        --silent \
        --show-error \
        --location \
        --connect-timeout 10 \
        --max-time 600 \
        --header "Accept: application/octet-stream" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$destination" \
        "$asset_url"
}

echo "Downloading $archive_name..."
download_asset "$archive_url" "$archive_path"

echo "Downloading $checksum_name..."
download_asset "$checksum_url" "$checksum_path"

(
    cd -- "$temporary_directory"
    sha256sum --check "$checksum_name"
)

python3 - "$archive_path" <<'PY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])

with tarfile.open(archive, "r:gz") as bundle:
    for member in bundle.getmembers():
        path = pathlib.PurePosixPath(member.name)

        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(
                f"Unsafe archive member: {member.name}"
            )

        if member.issym() or member.islnk():
            raise SystemExit(
                f"Archive links are not allowed: {member.name}"
            )

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

install -d \
    -m 0750 \
    -o root \
    -g root \
    "$project_directory"

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
    "$domain"

echo
echo "Crewline installation completed."
echo "Installed release: $release_tag"
echo
echo "The backend is prepared."
echo "Certificates and public HTTPS were intentionally not configured."
echo "Continue with Crewline's separate HTTPS activation procedure."