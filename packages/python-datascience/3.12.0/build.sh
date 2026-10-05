#!/bin/bash
# Builds Python 3.12 with the full AI/ML/DS library stack.
# The package directory becomes the install prefix (self-contained).

set -euo pipefail

PREFIX=$(realpath "$(dirname "$0")")

mkdir -p build
cd build

curl -fsSL "https://www.python.org/ftp/python/3.12.0/Python-3.12.0.tgz" -o python.tar.gz
tar xzf python.tar.gz --strip-components=1
rm python.tar.gz

./configure \
    --prefix "$PREFIX" \
    --with-ensurepip=install \
    2>&1 | tail -5

make -j"$(nproc)"
make install -j"$(nproc)"

cd ..
rm -rf build

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

# Ensure run and environment scripts are executable when packed into the tarball.
# The Makefile only chmod's build.sh; we handle the rest here.
chmod +x "$PREFIX/run" "$PREFIX/environment" 2>/dev/null || true
