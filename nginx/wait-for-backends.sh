#!/bin/sh
set -e

echo "[nginx-init] Waiting for Piston API backends..."
for host in api1 api2 api3; do
    i=0
    while ! nc -z "$host" 2000 2>/dev/null; do
        i=$((i+1))
        if [ "$i" -gt 60 ]; then
            echo "[nginx-init] Timeout waiting for $host:2000" >&2
            exit 1
        fi
        echo "[nginx-init] Waiting for $host:2000 ($i/60)..."
        sleep 2
    done
    echo "[nginx-init] $host is ready."
done

echo "[nginx-init] Waiting for terminal-service..."
i=0
while ! nc -z terminal-service 3000 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -gt 60 ]; then
        echo "[nginx-init] Timeout waiting for terminal-service:3000 — continuing anyway" >&2
        break
    fi
    echo "[nginx-init] Waiting for terminal-service:3000 ($i/60)..."
    sleep 2
done
[ "$i" -le 60 ] && echo "[nginx-init] terminal-service is ready."

echo "[nginx-init] All backends reachable — starting nginx."
exec /docker-entrypoint.sh "$@"
