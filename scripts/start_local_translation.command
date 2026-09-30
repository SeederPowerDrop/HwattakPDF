#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# This installer runs only when the user opens it, never on app launch.
set -euo pipefail

fail() {
    printf '\n%s\n' "$1" >&2
    printf '%s\n' 'Press Return to close this window.' >&2
    read -r _unused || true
    exit 1
}

script_directory="$(cd -- "$(dirname -- "$0")" && pwd)"
worker_path="$script_directory/translation_argos_worker.py"
runtime_directory="$HOME/Library/Application Support/HwattakPDF/LocalTranslation"
runtime_python="$runtime_directory/venv/bin/python3"

[[ -f "$worker_path" ]] || fail 'The translation helper is missing. Reinstall HwattakPDF or keep both helper files together.'

printf '%s\n' 'HwattakPDF local translation' 'This window prepares a private Python environment on first use, then runs the helper on this Mac.' 'The first setup needs internet access. PDF text stays on this Mac during local translation.'

if [[ ! -x "$runtime_python" ]]; then
    python_candidate=''
    for candidate in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3 /usr/local/bin/python3.12 /usr/local/bin/python3.11 /usr/local/bin/python3.13 /usr/local/bin/python3; do
        if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 13) else 1)' >/dev/null 2>&1; then
            python_candidate="$candidate"
            break
        fi
    done
    if [[ -z "$python_candidate" ]] && command -v python3 >/dev/null 2>&1; then
        candidate="$(command -v python3)"
        if "$candidate" -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 13) else 1)' >/dev/null 2>&1; then
            python_candidate="$candidate"
        fi
    fi
    [[ -n "$python_candidate" ]] || fail 'Python 3.10–3.13 is required. Install Python 3.12 from python.org or Homebrew, then open this launcher again.'
    mkdir -p "$runtime_directory"
    "$python_candidate" -m venv "$runtime_directory/venv" || fail 'Could not create the private Python environment. Check available disk space and folder permissions.'
fi

if ! "$runtime_python" -c 'import argostranslate.package' >/dev/null 2>&1; then
    printf '\n%s\n' 'Installing the local translation runtime into the private environment…'
    "$runtime_python" -m pip install --disable-pip-version-check --timeout 30 --retries 2 'argostranslate<2' || fail 'Argos Translate installation failed. Check your internet connection and retry. Python 3.12 is recommended if this Python version is unsupported.'
fi

printf '\n%s\n' 'Keep this window open while translating. Close it or press Control-C to stop.' 'In HwattakPDF, choose local language packs, check the connection, and explicitly download the language pairs you need.'
"$runtime_python" "$worker_path" --serve || fail 'The helper stopped. If port 17862 is already in use, another helper may already be running; close this window and check the connection in HwattakPDF.'
