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
    deepseek-harness-flake.url = "github:<你的用户名>/deepseek-harness-flake";
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
| `programs.deepseekHarness.gitRev` | 固定 commit | checkout 的 commit 或分支；改成 `"master"` 可追踪最新 |
| `programs.deepseekHarness.secretFile` | `/run/agenix/deepseek-api-key` | DeepSeek API key 来源（agenix 解密路径）；不存在则跳过，Web UI 手动填 |
| `programs.deepseekHarness.proxy` | `""` | git 代理（如 `http://127.0.0.1:7897`），空 = 直连 |
| `programs.deepseekHarness.port` | `3080` | Web UI 监听端口 |

## 更新 / 启动

- **更新**：改 `programs.deepseekHarness.gitRev` 后重新 home-switch，后台 `dsh-setup.service`
  会自动 fetch、checkout、重打补丁、按需重建。
  查看进度：`journalctl --user -u dsh-setup -f`
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
