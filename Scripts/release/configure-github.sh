#!/bin/bash
# 一次性配置：把发布所需的证书与公证密钥写进 GitHub 仓库的 Secrets。
# 在自己的 Mac 上运行（需要 gh 已登录：gh auth login）。每一项直接回车即跳过，可以分多次运行。
# 输入的密码与密钥只经由 gh 加密上传，不写入仓库、不留在本机文件里。
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v gh >/dev/null || { echo "需要 GitHub CLI：brew install gh && gh auth login" >&2; exit 1; }
# gh 靠当前目录的 git 远程地址认出是哪个仓库，所以要先把代码放进 git 并关联上 GitHub 仓库。
git rev-parse --git-dir > /dev/null 2>&1 || { echo "这个目录还不是 git 仓库：先 git init 并关联 GitHub 仓库（git remote add origin …），再运行本脚本。" >&2; exit 1; }
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner) || { echo "认不出 GitHub 仓库：先关联远程地址（git remote add origin https://github.com/<用户>/<仓库>.git）。" >&2; exit 1; }
echo "配置仓库：$repo"
echo

ask() { local prompt=$1 var; read -r -p "${prompt}：" var; printf '%s' "$var"; }
ask_secret() { local prompt=$1 var; read -r -s -p "${prompt}：" var; echo >&2; printf '%s' "$var"; }
secret() { printf '%s' "$2" | gh secret set "$1" --repo "$repo" > /dev/null && echo "  ✓ Secret $1"; }
# 拖进终端的路径：去掉首尾空格与引号，还原反斜杠转义的空格。
clean_path() { local p=$1; p=${p#"${p%%[![:space:]]*}"}; p=${p%"${p##*[![:space:]]}"}; p=${p%\'}; p=${p#\'}; p=${p%\"}; p=${p#\"}; printf '%s' "${p//\\ / }"; }

echo "【1/2】Developer ID 证书（钥匙串访问 → 我的证书 → 右键\"Developer ID Application: …\" → 导出为 .p12）"
p12=$(ask ".p12 文件路径（拖进终端即可）")
p12=$(clean_path "$p12")
if [[ -n $p12 ]]; then
    [[ -f $p12 ]] || { echo "找不到 $p12" >&2; exit 1; }
    password=$(ask_secret "导出 .p12 时设置的密码")
    secret MACOS_CERTIFICATE_P12 "$(base64 -i "$p12")"
    secret MACOS_CERTIFICATE_PASSWORD "$password"
    team=$(ask "团队 ID（证书名括号里的 10 位）")
    [[ -n $team ]] && secret APPLE_TEAM_ID "$team"
fi
echo

echo "【2/2】公证用的 App Store Connect API 密钥（App Store Connect → 用户和访问 → 集成 → 团队密钥，权限选\"开发者\"）"
p8=$(ask ".p8 文件路径（只能下载一次，请妥善保存）")
p8=$(clean_path "$p8")
if [[ -n $p8 ]]; then
    [[ -f $p8 ]] || { echo "找不到 $p8" >&2; exit 1; }
    secret NOTARY_KEY "$(cat "$p8")"
    key_id=$(ask "密钥 ID")
    [[ -n $key_id ]] && secret NOTARY_KEY_ID "$key_id"
    issuer=$(ask "Issuer ID（密钥列表上方的 UUID）")
    [[ -n $issuer ]] && secret NOTARY_ISSUER_ID "$issuer"
fi
echo

echo "当前配置："
gh secret list --repo "$repo"
gh variable list --repo "$repo"
