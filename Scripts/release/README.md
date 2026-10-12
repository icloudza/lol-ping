# 发布与在线更新

推送 `vX.Y.Z` 标签后，[`.github/workflows/release.yml`](../../.github/workflows/release.yml) 依次完成：

1. 按标签换算版本号与构建号（`version.sh`）
2. 跑 `Packages/LPCore` 和 `Packages/LPRooms` 的单元测试，不过就不发版
3. 用 XcodeGen 生成工程，归档、以 Developer ID 导出、重签 Sparkle 组件（`build.sh`）
4. 公证并装订应用，用 dmgbuild 打包 DMG（窗口布局见 `dmg/`），再签名、公证并装订 DMG
5. 用更新签名密钥签名安装包，生成并签名 `appcast.xml`（`publish.sh`）
6. 创建 GitHub Release，附上 `LolPing-<版本>.dmg`、`appcast.xml` 与更新说明（`notes.sh`）；GitHub 接口出错时自动重试
7. 从公网取回 `appcast.xml` 核对版本

应用内更新使用 [Sparkle](https://sparkle-project.org)：启动时与之后每小时检查一次 appcast，发现新版本后在应用内下载、校验、安装并重新打开。
更新地址固定为 `https://github.com/<仓库>/releases/latest/download/appcast.xml`，GitHub 会把它转到最新正式版 Release 的同名附件，
所以不需要另外的下载服务器。安装包和 appcast 都经过 EdDSA 签名校验。

1.0.1 及更早的版本没有 Sparkle，只会提示去发布页下载；从 1.0.2 起才能在应用内更新。

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
| `SPARKLE_PRIVATE_KEY` | Secret | 更新签名私钥 |
| `SPARKLE_PUBLIC_KEY` | Variable | 更新签名公钥，写入应用 |
| `MACOS_RUNNER` / `XCODE_PATH` | Variable | 可选：指定运行器与 Xcode，默认 `macos-26` 和其中最新的正式版 Xcode |

配置完成后，在 Actions → Release Check → Run workflow 跑一次发布前检查。它会验证证书、公证密钥和更新签名密钥，
并在运行器上跑一遍测试和不签名的 Release 编译，不发版。

**更新签名私钥必须备份。** 私钥存在本机钥匙串里（账户名 `lolping`），可以用下面的命令导出到安全位置：

```bash
"$(Scripts/release/sparkle-tools.sh)/generate_keys" --account lolping -x ~/lolping-sparkle-private-key
```

私钥一旦丢失，就无法再给已安装的用户签发更新，他们只能手动重新下载。

## 发布

更新说明写在 `ReleaseNotes/<版本>.md`，GitHub Release 和应用内的更新窗口共用这份说明。双语写法是列表项写中文，下一行缩进两格写英文：

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

预发布使用 `v1.1.0-beta.1` 或 `v1.1.0-rc.1` 这类标签：只生成 GitHub 预发布版本并上传安装包，不生成 appcast，已安装的应用不会收到它。
重新发布已有标签：Actions → Release → Run workflow，填入标签。

## 本地试跑

不公证、不上传，只验证构建、签名和 appcast 生成（需要钥匙串里有 Developer ID Application 证书）：

```bash
APPLE_TEAM_ID=XXXXXXXXXX UPDATE_FEED_URL=https://github.com/icloudza/lol-ping/releases/latest/download/appcast.xml SPARKLE_PUBLIC_KEY=… Scripts/release/build.sh v1.1.0
```

```bash
SPARKLE_PRIVATE_KEY="$(cat ~/lolping-sparkle-private-key)" SPARKLE_PUBLIC_KEY=… Scripts/release/publish.sh v1.1.0
```
