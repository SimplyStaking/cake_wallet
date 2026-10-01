#!/bin/sh

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "${CAKE_MACOS_SKIP_NATIVE:-0}" = "1" ]; then
    exec "$SCRIPT_DIR/build_dev_stubs.sh"
fi

./build_torch.sh

./build_monero_all.sh universal && ./build_decred.sh
