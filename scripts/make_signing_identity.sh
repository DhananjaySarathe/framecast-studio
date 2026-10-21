#!/bin/zsh
# Creates a self-signed "Framecast Local Signing" code-signing identity in a keychain file under
# build/signing (git-ignored). Nothing is added to the login keychain or trust settings.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/signing && cd build/signing
PASS=$(openssl rand -hex 16); echo "$PASS" > keychain.pass; chmod 600 keychain.pass
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Framecast Local Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cert.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:$PASS -legacy
security create-keychain -p "$PASS" "$PWD/framecast-signing.keychain-db"
security unlock-keychain -p "$PASS" "$PWD/framecast-signing.keychain-db"
security import id.p12 -k "$PWD/framecast-signing.keychain-db" -P "$PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$PWD/framecast-signing.keychain-db" >/dev/null
rm -f key.pem id.p12
