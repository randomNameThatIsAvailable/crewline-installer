# Crewline Installer

This repository contains the minimal public bootstrap installer for the
private Crewline application.

It does not contain Crewline source code, container images, secrets,
certificates, databases, media, or backups.

## Supported platform

- Debian 13
- AMD64
- Root installation
- Interactive terminal

## Install

Run as `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/randomNameThatIsAvailable/crewline-installer/main/install.sh)