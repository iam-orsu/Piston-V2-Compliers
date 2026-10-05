#!/bin/bash
# Builds Python 3.12 with the full data-science / AI-ML library stack.
# The package directory becomes the install prefix (self-contained, no system Python used).

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
    --enable-optimizations \
    2>&1 | tail -5

make -j"$(nproc)"
make install -j"$(nproc)"

cd ..
rm -rf build

# Core data-science stack
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

# Shared utilities that the base python package also provides
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
