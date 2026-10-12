#!/bin/bash
# 为 build.sh 的产物准备在线更新：用 EdDSA 私钥签名安装包 → 生成并签名 appcast.xml → 用应用内的公钥反验。
# 产物：build/release/appcast.xml，由发布工作流和安装包一起挂到 GitHub Release 上。
#
# 应用内的更新地址固定为 https://github.com/<仓库>/releases/latest/download/appcast.xml，
# GitHub 会把它转到最新正式版 Release 的同名附件，所以不需要另外的下载服务器。
#
# 用法：Scripts/release/publish.sh <标签>
#
# 环境变量：
#   SPARKLE_PRIVATE_KEY     EdDSA 私钥（generate_keys -x 导出的内容）
#   SPARKLE_PUBLIC_KEY      与私钥成对的公钥（应用 Info.plist 里的 SUPublicEDKey），用于核对
#   GITHUB_REPOSITORY       owner/repo，决定安装包的下载地址；默认取 project.yml 里的 LPUpdateRepo
set -euo pipefail
cd "$(dirname "$0")/../.."

tag=${1:?用法：publish.sh <标签>}
eval "$(Scripts/release/version.sh "$tag")"
: "${SPARKLE_PRIVATE_KEY:?缺少 SPARKLE_PRIVATE_KEY}"
: "${SPARKLE_PUBLIC_KEY:?缺少 SPARKLE_PUBLIC_KEY（用来核对私钥与应用内公钥是否一对）}"
repo=${GITHUB_REPOSITORY:-$(sed -n 's/^ *LPUpdateRepo: *//p' project.yml)}
[[ -n $repo ]] || { echo "不知道仓库名：设置 GITHUB_REPOSITORY" >&2; exit 1; }

out=build/release
dmg=$out/LolPing-$VERSION.dmg
[[ -f $dmg ]] || { echo "找不到 ${dmg}，先运行 build.sh" >&2; exit 1; }
tools=$(Scripts/release/sparkle-tools.sh)
key=$PWD/$out/.ed-key
# 私钥只在本次运行的临时文件里存在，结束即删。
trap 'rm -f "$key"' EXIT
(umask 077; printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key")

echo "▶ 签名安装包"
signature=$("$tools/sign_update" --ed-key-file "$key" "$dmg" | python3 Scripts/release/appcast.py --parse-signature)
# 用应用里内置的公钥反验：私钥与公钥不是一对时，所有用户都会拒绝这次更新，必须在发布前拦下。
swift Scripts/release/verify-signature.swift "$SPARKLE_PUBLIC_KEY" "$signature" "$dmg" \
    || { echo "安装包签名与 SPARKLE_PUBLIC_KEY 不匹配：私钥和公钥不是同一对。" >&2; exit 1; }

echo "▶ 生成并签名 appcast.xml"
Scripts/release/notes.sh "$tag" > "$out/notes.txt"
python3 Scripts/release/appcast.py --version "$VERSION" --build "$BUILD_NUMBER" --dmg "$dmg" \
    --url "https://github.com/$repo/releases/download/$tag/LolPing-$VERSION.dmg" \
    --notes "$out/notes.txt" --signature "$signature" --site "https://github.com/$repo" --out "$out"
"$tools/sign_update" --ed-key-file "$key" "$out/appcast.xml"
"$tools/sign_update" --verify --ed-key-file "$key" "$out/appcast.xml"

echo "✓ $out/appcast.xml"
