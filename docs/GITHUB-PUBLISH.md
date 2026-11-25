# 上传与发布

日后“上传代码”“提交”“合并”均默认只发布前端客户端；后台服务及本机运维工具保持本地，除非用户另行明确要求。安装包仅在用户要求时上传 Releases，不进入源码提交。

本仓库只提交 Flutter 客户端及其构建依赖，包括 `lib/`、Android/Windows 原生代码、`native/` 下载内核、`vendor_plugins/`、客户端测试和通用协议文档。客户端使用的规则引擎、来源脚本运行时及 `lib/data/parser_rules/server.dart` 等接口调用代码属于客户端，需要一起提交。

后台站点源码放在本仓库之外，不随本项目提交。仓库内的密码更新器 `tool/password_updater/`、启动脚本、后台规则测试 CLI 和构建脚本、后台部署与本机验收记录已忽略；`backend/`、`wwwroot/`、`5.com/` 也预留为后台副本的忽略目录。上述文件保留在本机，强制暂存后会被上传检查拒绝。

继续在本机编译正式版。`.local/`、`outputs/`、`dist/` 本机测试输出、日志、账号备份、签名、构建缓存和安装包已被忽略；不要通过网页拖入整个原始目录。本机磁盘清理面板及其启动脚本和说明也不进入源码仓库。

公告 HTML 编辑器及其配套测试、根目录公告工作文件、版本配置草稿和本地素材不进入源码仓库。公告功能源码、通用 JSON 示例、项目介绍和界面图片正常保留。检查脚本也会拒绝被强行加入暂存区的本地专用文件。

已有的 `远程配置编辑器.html` 是公开配置 JSON 的静态辅助工具，与其测试一起保留，不包含后台站点源码。

上传前检查：

```powershell
python tool/check_public_files.py
# git add 后检查暂存内容
python tool/check_public_files.py --staged
```

`.gitignore` 对已经跟踪的文件不生效，因此两项检查都要通过。CI 也会检查 Git 索引中的实际内容；它不会自动移除文件、提交或推送代码。

本机编译的 APK、EXE 单独上传 **Releases**，不要加入源码历史。同版本维护包需要用户手动安装；推送新版本更新时递增版本和构建号。

## 远程更新配置

更新字段中的 `version` 和 `build` 应与安装包一致；`downloadUrl` 填纯 HTTPS 地址，不能写成 Markdown 链接。

若同一个配置地址还服务 **0.3.47**，保持 `schema: 1`，`clouds` 只填写旧版认识的 8 项：`baidu`、`quark`、`uc`、`pan123`、`c139`、`tianyi`、`xunlei`、`lanzou`。新网盘字段会让旧版拒绝整份配置；省略这些字段时，新版中的新网盘仍默认开启。`config/control.example.json` 包含新网盘字段，仅供新版参考。

每次发布递增 `revision`，公告变更时更新 `id`，兼容旧版缓存判断。主配置访问失败后，应用才检查 GitHub 备用更新。

## 可选：GitHub Actions 打包

仓库配置 `release` Environment，在 Secrets 中设置：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Secrets 中另设 `ASTERLINK_CONTROL_URL`、`UMENG_APPKEY`；Variables 中设置 `ASTERLINK_GITHUB_REPO`、`ASTERLINK_APPLICATION_ID` 和 `UMENG_CHANNEL`。正式版包名为 `com.asterlink.app`；正式配置不完整时工作流会停止，本机参数不会自动上传。

修改 `pubspec.yaml` 后运行 `dart tool/sync_version.dart --write`。推送与完整版本一致的新标签，或在 Actions → Build signed release → Run workflow 选择分支，均可生成正式签名安装包。完成后下载 `release-android`、`release-windows`、`release-windows-arm64` 附件；工作流不会自动创建或发布 Release。需要发布时，再单独上传附件并发布版本。不要覆盖已发布标签。只有正式 Release 会被备用更新识别。

## 发布渠道：预发布与正式版

`ci.yml` 手动运行时有一个 `release_channel` 选项，决定这次运行发布什么：

| 选项 | tag | 标记 | 用途 |
| --- | --- | --- | --- |
| `prerelease`（默认） | `ci-<版本>-<运行号>`，重跑再加 `-attempt-N` | Pre-release | 每次运行独立留档，互不覆盖 |
| `release` | `v<版本>`，如 `v2.3.5+235` | Latest | 正式版，应用内备用更新能识别 |

两条渠道都没有 `--clobber`。预发布靠运行号保证 tag 唯一；正式版一个版本号只允许发一次，同名 tag 已存在时任务会提前失败并提示先升版本号。

应用内备用更新读的是 `GET /repos/<repo>/releases/latest`，该接口从不返回 pre-release，且 tag 必须能解析成 `v1.2.3+456` 形式。所以 `ci-*` 想改成正式版，**光取消 pre-release 勾选不够**，tag 也要改：

```bash
# 网页：Releases → 该记录 → Edit release → 取消 "Set as a pre-release"，勾选 "Set as the latest release"
# 命令行等价操作（同时把 tag 改成正式版格式）
gh release edit ci-2.3.5-235-7 --tag v2.3.5+235 --prerelease=false --latest
```

注意备用更新的仓库来自构建期 `ASTERLINK_GITHUB_REPO`（`config/build.community.json` 里为空，community 包因此不查询 GitHub），且只对 Android / Windows / macOS 生效，Linux 包不参与这条链路。

