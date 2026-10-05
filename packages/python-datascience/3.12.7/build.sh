#!/bin/bash
# Installs a self-contained Python 3.12.7 using a pre-built binary distribution
# (python-build-standalone by Gregory Szorc). Avoids compiling from source —
# download + pip install takes ~5-8 min instead of 20-35 min.
set -euo pipefail

PREFIX=$(realpath "$(dirname "$0")")

PBS_TAG="20241016"
PYTHON_VER="3.12.7"
PBS_FILE="cpython-${PYTHON_VER}+${PBS_TAG}-x86_64_v2-unknown-linux-gnu-install_only.tar.gz"
PBS_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"

echo "Downloading Python ${PYTHON_VER} (pre-built binary, ~60 MB)..."
curl -fsSL "$PBS_URL" | tar xzf - -C "$PREFIX" --strip-components=1
echo "Python ${PYTHON_VER} extracted."

# Core data-science / AI-ML stack
"$PREFIX/bin/pip3" install --no-cache-dir \
    numpy \
    scipy \
    pandas \
    matplotlib \
    seaborn \
    scikit-learn \
    pillow \
    statsmodels \
    plotly \
    openpyxl \
    xlrd

# Shared utilities present in the base python package
"$PREFIX/bin/pip3" install --no-cache-dir \
    pycryptodome \
    whoosh \
    bcrypt \
    passlib \
    sympy \
    xxhash \
    base58 \
    cryptography \
    PyNaCl

chmod +x "$PREFIX/run" "$PREFIX/environment" 2>/dev/null || true
