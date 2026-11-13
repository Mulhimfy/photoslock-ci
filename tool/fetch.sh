#!/bin/bash
# Download a run's sealed output and decrypt it locally.
#   tool/fetch.sh <run-id> [dest-dir]
set -eu
RUN=$1
DEST=${2:-/tmp/claude-0/photoslock-ci-$RUN}
mkdir -p "$DEST"
gh run download "$RUN" -R Mulhimfy/photoslock-ci -n sealed -D "$DEST/dl"
# The secret may or may not keep the key file's trailing newline: try both.
K1=$(cat /root/.config/photoslock-ci/artifact.key)
export K1 K2="$K1"$'\n'
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:K1 -in "$DEST/dl/out.tgz.sealed" -out "$DEST/out.tgz" 2>/dev/null \
  || openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:K2 -in "$DEST/dl/out.tgz.sealed" -out "$DEST/out.tgz"
tar xzf "$DEST/out.tgz" -C "$DEST"
rm -rf "$DEST/dl" "$DEST/out.tgz"
echo "$DEST/out"
