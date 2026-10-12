# 发布

推送 `vX.Y.Z` 标签后，[`.github/workflows/release.yml`](../../.github/workflows/release.yml) 依次完成：

1. 按标签换算版本号与构建号（`version.sh`）
2. 跑 `Packages/LPCore` 和 `Packages/LPRooms` 的单元测试，不过就不发版
3. 用 XcodeGen 生成工程，归档并以 Developer ID 导出（`build.sh`）
4. 公证并装订应用，用 dmgbuild 打包 DMG（窗口布局见 `dmg/`），再签名、公证并装订 DMG
5. 创建 GitHub Release，附上 `LolPing-<版本>.dmg` 与更新说明（`notes.sh`）；GitHub 接口出错时自动重试

应用内的更新检查读的是这个仓库的最新 Release（`project.yml` 里的 `LPUpdateRepo`）：发现版本号更高的正式版就提醒，
并打开发布页让用户自己下载。应用不会自动下载或安装，所以不需要另外的下载服务器和更新签名密钥。

## 一次性配置

在仓库根目录运行配置向导，按提示填写（每项可以回车跳过，之后再补）：

```bash
Scripts/release/configure-github.sh
```

| 名称 | 类型 | 内容 |
| --- | --- | --- |
| `MACOS_CERTIFICATE_P12` | Secret | Developer ID Application 证书（.p12，base64） |
| `MACOS_CERTIFICATE_PASSWORD` | Secret | .p12 的导出密码 |
| `APPLE_TEAM_ID` | Secret | 团队 ID |
| `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` | Secret | App Store Connect API 密钥，用于公证 |
| `MACOS_RUNNER` / `XCODE_PATH` | Variable | 可选：指定运行器与 Xcode，默认 `macos-26` 和其中最新的正式版 Xcode |

配置完成后，在 Actions → Release Check → Run workflow 跑一次发布前检查。它会验证证书和公证密钥，
并在运行器上跑一遍测试和不签名的 Release 编译，不发版。

## 发布

更新说明写在 `ReleaseNotes/<版本>.md`，会成为 GitHub Release 的正文。双语写法是列表项写中文，下一行缩进两格写英文：

```markdown
- 快捷键可以完全自定义
  Every shortcut can be changed
```

没有这个文件时，依次退回到附注标签的说明、上一个标签以来的提交标题。写好后提交，再推送标签：

```bash
git tag v1.1.0
```

```bash
git push origin v1.1.0
```

预发布使用 `v1.1.0-beta.1` 或 `v1.1.0-rc.1` 这类标签：生成的是 GitHub 预发布版本，应用内的更新检查不会提示它。
重新发布已有标签：Actions → Release → Run workflow，填入标签。

## 本地试跑

不公证、不上传，只验证构建与签名链路（需要钥匙串里有 Developer ID Application 证书）：

```bash
APPLE_TEAM_ID=XXXXXXXXXX Scripts/release/build.sh v1.1.0
```
