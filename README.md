# deepseek-harness-flake

DeepSeek Harness（dsh）的 **home-manager 模块**，独立 flake。

dsh 是 DeepSeek 官方的测试/评测工具（`deepseek-ai/deepseek-harness`），处于 dev preview
阶段，上游 API/结构随时会变。本模块采用「**后台克隆 + 构建**」的轻量策略，不把整个 JS
monorepo 编进 nix store：

- 换 pin、上游变动都不需要改 hash / 依赖树，只影响 `~/deepseek-harness` 一份本地 checkout
- 关掉开关即可整机清除（激活脚本删除 `~/deepseek-harness` 与 `~/.dsh`）

## 用法

### 作为 flake input（推荐）

```nix
# flake.nix
{
  inputs = {
    deepseek-harness-flake.url = "github:Loyage/deepseek-harness-flake";
    # ...
  };
  outputs = { deepseek-harness-flake, ... }: {
    homeConfigurations.foo = home-manager.lib.homeManagerConfiguration {
      modules = [
        # 引入模块（默认关闭，不影响其它配置）
        deepseek-harness-flake.homeModules.default
        # 按主机开启
        { programs.deepseekHarness.enable = true; }
      ];
      # ...
    };
  };
}
```

### NixOS / nix-darwin 里给 home-manager 用

```nix
# 在 home-manager 的 imports 里加一行：
imports = [
  inputs.deepseek-harness-flake.homeModules.default
];

# 然后按主机开启：
programs.deepseekHarness.enable = true;
```

## 选项

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `programs.deepseekHarness.enable` | `false` | 启用（后台服务克隆+构建）。关闭即删除 `~/deepseek-harness` 与 `~/.dsh` |
| `programs.deepseekHarness.startAtBoot` | `false` | 登录后自动启动 Web UI（Linux: systemd user 服务；macOS: LaunchAgent） |
| `programs.deepseekHarness.gitRev` | 本 flake 锁定版本 | checkout 的 commit；默认 = `pinnedVersion`（flake.lock 锁定），只有更新本 flake 输入才会变 |
| `programs.deepseekHarness.pinnedVersion` | flake.lock 锁定 rev | **只读**：本 flake 锁定的 dsh 版本，可用 `home-manager show-config` 查看 |
| `programs.deepseekHarness.secretFile` | `/run/agenix/deepseek-api-key` | DeepSeek API key 来源（agenix 解密路径）；不存在则跳过，Web UI 手动填 |
| `programs.deepseekHarness.proxy` | `""` | git 代理（如 `http://127.0.0.1:7897`），空 = 直连 |
| `programs.deepseekHarness.port` | `3080` | Web UI 监听端口 |

## 版本策略（固定版本）

本 flake 把 `deepseek-ai/deepseek-harness` 作为 **`flake = false` 的输入** 锁定在
`flake.lock` 里——**安装/重建的 dsh 版本号就固定在这个 commit 上**：

- `programs.deepseekHarness.gitRev` 默认 = 锁定版本，后台 `dsh-setup` 只 checkout 这个 commit
- 构建指纹（锁定 rev + `dsh-tsconfig.patch` 内容 hash）写入 `~/deepseek-harness/.dsh-nix-rev`，
  指纹不变就跳过 `pnpm install + build`：
  普通 flake 改动、nixpkgs 升级、反复 home-switch 都**不会**重新编译
- 查看当前锁定版本：`nix flake metadata`（或 `home-manager show-config` 里的 `pinnedVersion`）

**升级 dsh（唯一途径）**：改 `flake.nix` 里 `deepseek-harness` 输入的 rev，然后

```bash
nix flake lock --update-input deepseek-harness
# 提交 flake.nix + flake.lock 后，重新 home-switch / just switch
```

后台 `dsh-setup.service` 会自动 fetch、checkout、重打补丁、按需重建
（查看进度：`journalctl --user -u dsh-setup -f`）。

> 注意：把 `gitRev` 改成 `"master"` 等分支名可追踪上游最新，但**上游每次变动都会触发
> 重新编译**，与固定版本的目标相悖。

## 启动 / 清除

- **启动**：`~/dsh-lab/dsh-web.sh start`（或 `startAtBoot = true` 开机自启）
- **清除**：把 `enable` 改回 `false` 后 switch，激活时自动删除全部痕迹

## 已知事项

- git clone / pnpm install 需要网络；GitHub 不通的机器请配 `programs.deepseekHarness.proxy`
  （如 `http://127.0.0.1:7897`），npm registry 走 `~/.npmrc` 或默认源
- 上游要求 pnpm >= 11.7.0（`packageManager` 字段）。11.2.x 解析 `pnpm-workspace.yaml` 的
  `allowBuilds` 里 `file:` 协议条目会抛 `ERR_PNPM_INVALID_VERSION_UNION`。
  本模块**自包含版本保障**（`lib/pnpm.nix`）：当前 nixpkgs 的 `pnpm_11` 直接可用，
  旧 nixpkgs 自动 override 到 11.7.0，消费方无需额外 overlay
- 安装/更新在 systemd user 服务 `dsh-setup` 里后台跑（`Type=oneshot`，`TimeoutStartSec=0`），
  switch 不会被阻塞，也不会因首次 clone/install 超过 5 分钟激活超时被杀
- 上游 rc.5 缺两条 tsconfig paths（directory-picker 两个 client 包），由 `dsh-tsconfig.patch`
  在激活期自动打上；上游修复后会自动跳过
- HMR 服务要求 node 带 `--expose-internals`（不能走 `NODE_OPTIONS`），且必须在仓库目录启动
  （tsx 需要仓库根 `tsconfig.json` 的 paths 映射），模块里的启动命令已处理

## 开发

```bash
nix flake check   # 冒烟测试：enable = true 求值 + 构建激活脚本
```

## 结构

```
flake.nix                      # 入口：homeModules.default + checks
modules/deepseek-harness.nix   # home-manager 模块本体
lib/pnpm.nix                   # pnpm >= 11.7.0 版本保障（条件 override）
dsh-tsconfig.patch             # 上游缺失的 tsconfig paths 补丁
```
