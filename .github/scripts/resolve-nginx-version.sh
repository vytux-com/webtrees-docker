#!/bin/sh
# Print the nginx version (without the -rN package revision) currently
# available in the Alpine release the Dockerfile builds on.
set -eu

alpine=$(sed -n 's/^ARG ALPINE_VERSION=//p' Dockerfile | head -n1)

docker run --rm "alpine:${alpine}" sh -c 'apk update -q && apk search -x -v nginx' |
    sed -n 's/^nginx-\([0-9][0-9.]*\)-r[0-9][0-9]*\( .*\)\{0,1\}$/\1/p' |
    head -n1
