#!/bin/sh
# Initialize tmpfs home with default config files, then exec the real shell.
# Runs as uid 1000 (sandbox user) — tmpfs /home/sandbox is pre-owned 1000:1000.
cp /etc/skel/.bashrc       /home/sandbox/.bashrc       2>/dev/null || true
cp /etc/skel/.bash_profile /home/sandbox/.bash_profile 2>/dev/null || true
cp /etc/skel/.profile      /home/sandbox/.profile      2>/dev/null || true
exec "$@"
