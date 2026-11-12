# Repository Guidelines

## Project Structure & Module Organization

This repository contains one executable Bash script, `check_kernel.sh`. It checks kernel.org for newer Linux kernels, downloads and extracts sources under `/usr/src`, configures and builds them, installs boot artifacts under `/boot`, and updates GRUB. There are currently no separate source, test, asset, or documentation directories. Keep related behavior in the existing script and organize new logic into small, clearly named functions.

## Build, Test, and Development Commands

The script is an operational installer rather than a library, so development checks should be lightweight and explicit:

```bash
bash -n check_kernel.sh              # syntax validation
shellcheck check_kernel.sh           # static analysis, when installed
bash check_kernel.sh --help          # inspect the CLI without building
bash check_kernel.sh --list          # list kernel versions (network access)
```

Normal build/install commands require root and a Linux host with `curl`, `wget`, `tar`, `make`, `update-initramfs`, and `update-grub`; for example, `sudo bash check_kernel.sh -A -t 6.12`. Do not run install paths casually: they can remove or replace kernel files and boot symlinks.

## Coding Style & Naming Conventions

Use Bash with `#!/usr/bin/env bash`, `set -euo pipefail`, and the existing two-space indentation. Prefer lowercase `snake_case` function names, uppercase names for exported or global configuration variables, and `local` variables inside functions. Quote expansions, validate required arguments, and preserve the script’s clear status/error messages. Keep option aliases and help text synchronized when changing the CLI.

## Testing Guidelines

No automated test suite is present. Every change should pass `bash -n`; run ShellCheck if available. Exercise non-destructive paths such as `--help` and, when network access is acceptable, `--list`. Test download, configuration, and installation changes only in a disposable or explicitly approved environment, ideally with mocked commands or a throwaway kernel tree.

## Commit & Pull Request Guidelines

Git history is not available in this checkout, so no repository-specific commit convention can be inferred. Use short imperative subjects (for example, `Validate exact kernel versions`) and keep commits focused. Pull requests should explain behavior changes, list validation commands and results, call out root/filesystem/bootloader effects, and include help-output examples when the CLI changes.

## Security & Configuration Tips

Review network URLs, extracted paths, and command arguments before execution. Preserve confirmation prompts and avoid weakening root checks. Never commit credentials, local kernel configuration, or machine-specific `/boot` and `/usr/src` output.
