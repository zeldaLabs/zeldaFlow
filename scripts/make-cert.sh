#!/bin/bash
# Create a stable self-signed code-signing certificate ("zeldaFlow Dev") so
# macOS TCC permissions (Accessibility, Microphone) survive rebuilds.
# Ad-hoc signatures change every build, which makes macOS treat each rebuild
# as a brand-new app and silently drop its permission grants.
#
# After running this, open Keychain Access → My Certificates → "zeldaFlow Dev"
# → double-click → Trust → Code Signing: Always Trust. Then rebuild.
set -euo pipefail

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$DIR/dev.key" -out "$DIR/dev.crt" \
  -subj "/CN=zeldaFlow Dev" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

openssl pkcs12 -export -legacy -in "$DIR/dev.crt" -inkey "$DIR/dev.key" \
  -out "$DIR/dev.p12" -password pass:zeldaFlow

security import "$DIR/dev.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P zeldaFlow -T /usr/bin/codesign

echo
echo "Certificate imported and ready — no Keychain Access step needed."
echo "codesign accepts a self-signed identity even though the keychain marks"
echo "it untrusted; scripts/build-app.sh picks it up automatically."
echo
echo "Next: scripts/install.sh, then grant Microphone + Accessibility once."
echo "Those grants now survive every future rebuild."
