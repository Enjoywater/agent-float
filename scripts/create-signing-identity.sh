#!/bin/sh
# ad-hoc 서명은 빌드할 때마다 서명이 달라져 손쉬운 사용·자동화 권한이 풀린다.
# 로그인 키체인에 로컬 전용 코드 서명 인증서를 하나 두고 그것으로 서명하면 한 번 허용한 권한이 유지된다 (v1.2 설계 4.9)
set -eu

name="${SIGN_IDENTITY:-Agent Float Local Signing}"
keychain="$HOME/Library/Keychains/login.keychain-db"
# 키체인이 받아 주는 PKCS#12 형식을 내도록 시스템 openssl(LibreSSL)을 고정해 쓴다
openssl=/usr/bin/openssl

if security find-identity -v -p codesigning "$keychain" | grep -F -q "\"$name\""; then
	echo "이미 있습니다: $name"
	exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 신뢰 창에서 취소했다면 인증서는 이미 들어가 있으니 다시 만들지 않고 신뢰만 다시 묻는다
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
	# 가져오기에만 쓰고 버리는 일회용 암호
	pass=$("$openssl" rand -hex 16)
	"$openssl" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
		-name "$name" -out "$work/identity.p12" -passout "pass:$pass"
	security import "$work/identity.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign
fi

echo "macOS 암호 창이 뜨면 허용해 주세요 (코드 서명용으로만 신뢰)"
security add-trusted-cert -p codeSign -k "$keychain" "$work/cert.pem"
security find-identity -v -p codesigning "$keychain" | grep -F "\"$name\""
