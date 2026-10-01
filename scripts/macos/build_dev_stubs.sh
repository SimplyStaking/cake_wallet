#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR="$SCRIPT_DIR/../.."
MWEB_HEADER="$ROOT_DIR/cw_mweb/android/src/main/jniLibs/arm64-v8a/libmweb.h"
TORCH_STUB_DIR="$ROOT_DIR/scripts/torch_dart"

if [[ ! -f "$TORCH_STUB_DIR/pubspec.yaml" ]]; then
    mkdir -p "$TORCH_STUB_DIR/lib"
    cat > "$TORCH_STUB_DIR/pubspec.yaml" <<'EOF'
name: torch_dart
version: 0.0.1
environment:
  sdk: ^3.6.2
EOF
    cat > "$TORCH_STUB_DIR/lib/abstract_tor.dart" <<'EOF'
abstract class Tor {
  String? get version;
  void start(List<String> argv);
  String toJson();

  static Future<List<Tor>> getTorList() async => [];
}
EOF
fi

# These directories are listed as Flutter assets but contain no tracked files.
for asset_dir in \
    assets/new-ui/icons \
    assets/new-ui/hero \
    assets/new-ui/balance_card_icons \
    assets/new-ui/balance_card_backgrounds \
    assets/new-ui/settings_row_icons \
    assets/new-ui/chain_badges \
    assets/new-ui/address-type-picker-icons \
    assets/new-ui/address-type-picker-icons/zec \
    assets/new-ui/trade_providers \
    assets/new-ui/navbar \
    assets/new-ui/card_icons \
    assets/new-ui/card_icons/chain_icons \
    assets/new-ui/card_icons/og_icons \
    assets/new-ui/card_icons/outline_icons \
    assets/new-ui/card_icons/symbol_icons \
    assets/new-ui/crypto_full_icons \
    assets/new-ui/hardware_wallets \
    assets/new-ui/node_speed_badges \
    assets/new-ui/address_sources; do
    mkdir -p "$ROOT_DIR/$asset_dir"
done

make_empty_dylib() {
    local output="$1"

    if [[ -f "$output" ]]; then
        return
    fi

    printf '%s\n' 'void cake_wallet_dev_stub(void) {}' |
        cc -x c - -dynamiclib -o "$output"
    echo "Created development stub: $output"
}

mkdir -p "$(dirname "$MWEB_HEADER")"

# ffigen needs a header even though this profile does not build MWEB.
if [[ ! -f "$ROOT_DIR/cw_mweb/lib/generated_bindings.g.dart" ]]; then
    cat > "$MWEB_HEADER" <<'EOF'
int StartServer(char *chain, char *dataDir, char *nodeUri, char **errMsg);
void StopServer(void);
char *Addresses(char *scanSecret, int scanSecretLen, char *spendPubKey,
                int spendPubKeyLen, int fromIndex, int toIndex);
EOF
    (
        cd "$ROOT_DIR"
        dart run ffigen --config cw_mweb/ffigen_config.yaml
    )
fi

make_empty_dylib "$ROOT_DIR/macos/libmonero_wallet2_api_c.dylib"
make_empty_dylib "$ROOT_DIR/macos/libwownero_wallet2_api_c.dylib"
make_empty_dylib "$ROOT_DIR/macos/mweb.dylib"

echo "Native wallet implementations are disabled for this development build."
