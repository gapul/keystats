#!/usr/bin/env bash
# keystats 配布用の 10 年有効な自己署名コード署名証明書を専用キーチェーンに作る。
# Apple Development 証明書(期限1年)の代わりにこれで全リリースを署名する = 期限切れで
# 指定要件(DR)が変わり全ユーザーの入力監視が外れる、を防ぐ。
# 完全非対話(キーチェーンのパスワードは自分で生成して保持するので set-key-partition-list が通る)。
set -euo pipefail

CN="Keystats Signing"
CFG="$HOME/.config/keystats"
PW_FILE="$CFG/signing.pw"
KC="$HOME/Library/Keychains/keystats-signing.keychain-db"

mkdir -p "$CFG"; chmod 700 "$CFG"
[ -f "$PW_FILE" ] || { openssl rand -hex 24 > "$PW_FILE"; chmod 600 "$PW_FILE"; }
PW="$(cat "$PW_FILE")"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$CN"; then
  echo "既に存在: $CN"
  security find-identity -p codesigning "$KC" | grep "$CN"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG2
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$CN
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG2

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" -extensions v3 2>/dev/null
# -legacy: OpenSSL 3 既定の PKCS12(AES/SHA256)は macOS の security が読めないため旧形式で出力。
# 空パスワードだと MAC 検証で弾かれるのでキーチェーンPWを流用。
openssl pkcs12 -export -legacy -macalg sha1 -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:"$PW"

security create-keychain -p "$PW" "$KC" 2>/dev/null || true
security set-keychain-settings "$KC"          # 自動ロック無効
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1
# 検索リストに追加(既存を保持)
security list-keychains -d user -s "$KC" $(security list-keychains -d user | sed 's/[" ]//g')

echo "作成完了:"
security find-identity -p codesigning "$KC" | grep "$CN" || echo "(find-identity に出ない場合も codesign -s \"$CN\" で署名可能)"
