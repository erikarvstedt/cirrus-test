#!/usr/bin/env bash

# This script can also be run locally for testing:
#   scenario=default ./build.sh
#
# It leaves no persistent traces on the host system (when variable CIRRUS_CI is unset).

set -euo pipefail
set -x

scenario=${scenario:-}
CACHIX_SIGNING_KEY=${CACHIX_SIGNING_KEY:-}
binaryCache=nix-bitcoin-ci-ea

if [[ -v CIRRUS_CI ]]; then
    tmpDir=/tmp
    if [[ $scenario ]]; then
        if [[ ! -e /dev/kvm ]]; then
            >&2 echo "No KVM available on VM host."
            exit 1
        fi
        # Enable KVM access for the nixbld users
        chmod o+rw /dev/kvm
    fi
else
    tmpDir=$(mktemp -d -p /tmp)
    trap "rm -rf $tmpDir" EXIT
    # Prevent cachix from writing to HOME
    export HOME=$tmpDir
fi

cachix use $binaryCache
cd "${BASH_SOURCE[0]%/*}"

## Build

echo "$NIX_PATH ($(nix eval --raw nixpkgs.lib.version))"

if [[ $scenario ]]; then
    buildExpr=$(../test/run-tests.sh --scenario $scenario exprForCI)
else
    buildExpr="import ./build.nix"
fi

time nix-instantiate -E "$buildExpr" --add-root $tmpDir/drv --indirect

outPath=$(nix-store --query $tmpDir/drv)
if nix path-info --store https://nix-bitcoin.cachix.org $outPath &>/dev/null; then
    echo "$outPath" has already been built successfully.
    exit 0
fi

# Cirrus doesn't expose secrets to pull-request builds,
# so skip cache uploading in this case
if [[ $CACHIX_SIGNING_KEY ]]; then
    cachix push $binaryCache --watch-store &
    cachixPid=$!
fi

nix-build $tmpDir/drv

if [[ $CACHIX_SIGNING_KEY ]]; then
    # Wait until cachix has finished uploading
    nix run -f '<nixpkgs>' ruby -c ../helper/wait-for-network-idle.rb $cachixPid
fi
