#!/usr/bin/env bash
# ローカル開発用の自己署名 Code Signing 証明書を作成する。
#
# 目的: ad-hoc 署名 (CODE_SIGN_IDENTITY="-") の CDHash ドリフトによる
#       TCC 権限リセット問題を回避する。自己署名 cert を使うと
#       Designated Requirement が "bundle ID + cert root hash" に固定され、
#       再ビルドしても macOS が「同じアプリ」と認識し続ける。
#
# 使い方:
#   scripts/setup_dev_cert.sh
#
# 前提: 他の Mac でビルドする場合 or 証明書が消えた場合に実行する。
# 既に証明書が存在する場合は何もしない。
#
# 作成される cert:
#   - Common Name: CaptionCraft Local Dev
#   - 有効期間: 10 年
#   - login.keychain-db に保存
#   - codesign / productsign からのアクセスを許可
#
# 詳細: TASKS/PERMISSIONS_GUIDE.md §1.2

set -euo pipefail

CERT_NAME="CaptionCraft Local Dev"

if security find-identity -p codesigning | grep -q "$CERT_NAME"; then
    echo "OK: 証明書 '$CERT_NAME' は既にインストール済みです。"
    exit 0
fi

CERT_DIR=$(mktemp -d)
trap 'rm -rf "$CERT_DIR"' EXIT
cd "$CERT_DIR"

cat > cert.cnf <<'EOF'
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_ca

[ dn ]
CN = CaptionCraft Local Dev
O  = Veltrea Local
C  = JP

[ v3_ca ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "--- 秘密鍵 + 自己署名証明書を生成"
/usr/bin/openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout key.pem -out cert.pem \
  -days 3650 -config cert.cnf 2>/dev/null

echo "--- PKCS12 形式に変換"
/usr/bin/openssl pkcs12 -export -out cert.p12 \
  -inkey key.pem -in cert.pem \
  -passout pass:temp 2>/dev/null

echo "--- login.keychain にインポート"
security import cert.p12 \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P temp \
  -T /usr/bin/codesign \
  -T /usr/bin/productsign

echo ""
echo "OK: 証明書 '$CERT_NAME' を作成しました。"
echo ""
echo "次のステップ:"
echo "  1. scripts/reset_tcc.sh     (古い TCC エントリを掃除)"
echo "  2. xcodegen generate        (pbxproj 再生成)"
echo "  3. ビルド → 起動 → 権限付与 → Cmd-Q → 再起動"
echo ""
echo "cert を削除したい時:"
echo "  security delete-identity -c '$CERT_NAME'"
