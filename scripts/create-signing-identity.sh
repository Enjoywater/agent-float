#!/bin/sh
# Ad-hoc signatures change on each build and invalidate Accessibility/Automation approvals.
# Use a local-only signing certificate in the login keychain to preserve granted permissions (v1.2 design §4.9).
set -eu

name="${SIGN_IDENTITY:-Agent Float Local Signing}"
keychain="$HOME/Library/Keychains/login.keychain-db"
# Pin system LibreSSL to generate PKCS#12 compatible with Keychain import.
openssl=/usr/bin/openssl

if security find-identity -v -p codesigning "$keychain" | grep -F -q "\"$name\""; then
	echo "이미 있습니다: $name"
	exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# After cancelling trust, the certificate is already imported; request trust again instead of recreating it.
if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
	security find-certificate -c "$name" -p "$keychain" >"$work/cert.pem"
else
	cat >"$work/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $name
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF
	"$openssl" req -x509 -newkey rsa:2048 -days 3650 -nodes \
		-config "$work/openssl.cnf" -extensions ext \
		-keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
	# Disposable password used only during import.
	pass=$("$openssl" rand -hex 16)
	"$openssl" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
		-name "$name" -out "$work/identity.p12" -passout "pass:$pass"
	security import "$work/identity.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign
fi

echo "macOS 암호 창이 뜨면 허용해 주세요 (코드 서명용으로만 신뢰)"
security add-trusted-cert -p codeSign -k "$keychain" "$work/cert.pem"
security find-identity -v -p codesigning "$keychain" | grep -F "\"$name\""
