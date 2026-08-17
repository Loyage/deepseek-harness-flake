# DeepSeek Harness (dsh) —— home-manager 模块
#
# ⚠️ 项目处于早期阶段（dev preview），上游 API/结构随时可能变化，因此本模块采用
# 「后台克隆 + 构建」的轻量策略，而不是把整个 JS monorepo 编进 nix store：
#   - 换 pin、上游变动都不需要改 hash / 依赖树，只影响 ~/deepseek-harness 一份本地 checkout
#   - 关掉开关即可整机清除（激活脚本删除 ~/deepseek-harness 与 ~/.dsh）
#
# 用法（默认关闭，按主机显式开启）：
#   在目标主机的 home-manager 配置里设 programs.deepseekHarness.enable = true，
#   其余主机保持默认 false，既不克隆也不构建，switch 时自动清理旧痕迹。
#
# 版本策略（固定版本，除非本 flake 显式更新）：
#   - dsh 版本 = 本 flake 的 flake.lock 锁定的 commit（inputs.deepseek-harness，flake=false）
#   - programs.deepseekHarness.gitRev 默认 = 该锁定版本；后台 dsh-setup 只 checkout 这个 commit
#   - 构建指纹（锁定 rev + 补丁文件 hash）写入 ~/deepseek-harness/.dsh-nix-rev，
#     指纹不变就跳过 pnpm install + build：普通 flake 改动 / nixpkgs 升级 / 反复 switch 不重编译
#   - 更新 dsh 的唯一途径：改 flake.nix 里 deepseek-harness 输入的 rev，然后
#     nix flake lock --update-input deepseek-harness，再 home-switch / just switch
#     （查看进度：journalctl --user -u dsh-setup -f）
#
# 启动：~/dsh-lab/dsh-web.sh start（或 startAtBoot = true 开机自启）
#
# 已知事项：
#   - git clone / pnpm install 需要网络；GitHub 不通的机器请配 programs.deepseekHarness.proxy
#     （如 "http://127.0.0.1:7897"），npm registry 走 ~/.npmrc 或默认源
#   - 上游要求 pnpm >= 11.7.0（packageManager 字段）。本模块已自包含版本保障
#     （lib/pnpm.nix：当前 nixpkgs 直接可用，旧 nixpkgs 自动 override 到 11.7.0），
#     因为 11.2.x 解析 pnpm-workspace.yaml 的 allowBuilds 里 file: 协议条目会抛
#     ERR_PNPM_INVALID_VERSION_UNION
#   - 安装/更新在 systemd user 服务 dsh-setup 里后台跑（Type=oneshot，TimeoutStartSec=0），
#     switch 不会被阻塞，也不会因首次 clone/install 超过 5 分钟激活超时被杀
#   - 上游 rc.5 缺两条 tsconfig paths（directory-picker 两个 client 包），由同目录
#     dsh-tsconfig.patch 在激活期自动打上；上游修复后会自动跳过
#   - HMR 服务要求 node 带 --expose-internals（不能走 NODE_OPTIONS），
#     且必须在仓库目录启动（tsx 需要仓库根 tsconfig.json 的 paths 映射），脚本里已处理

{ pinnedRev }:
{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib) types;
  cfg = config.programs.deepseekHarness;

  # 自包含的 pnpm（版本保障见 lib/pnpm.nix）
  pnpm = import ../lib/pnpm.nix { inherit pkgs; };

  home = config.home.homeDirectory;
  repo = "${home}/deepseek-harness";
  dshHome = "${home}/.dsh";
  labDir = "${home}/dsh-lab";
  logFile = "${labDir}/web.log";
  marker = "${repo}/.dsh-nix-rev";

  # 上游缺失的 tsconfig paths 补丁（见文件头说明）
  patchFile = ./../dsh-tsconfig.patch;

  # 启动命令（web profile）：--expose-internals + 仓库目录 + tsx paths
  startCmd = pkgs.writeShellScript "dsh-web-start" ''
    cd "${repo}"
    export DSH_TELEMETRY_DISABLED=1
    exec "${pkgs.nodejs}/bin/node" --expose-internals \
      --import tsx/esm apps/cli/src/bin.ts web \
      --host 127.0.0.1 --port ${toString cfg.port}
  '';

  # 安装/更新脚本：幂等，靠 marker（.dsh-nix-rev）跳过已构建的 rev
  setupScript = pkgs.writeShellScript "dsh-setup" ''
    set -u
    # 激活环境 PATH 很精简，显式补充所需命令（node/git/grep/sed/pkill/coreutils/curl）
    export PATH="${pkgs.nodejs}/bin:${pkgs.git}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:${pkgs.curl}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    REPO="${repo}"; DSH="${dshHome}"; LAB="${labDir}"
    REV="${cfg.gitRev}"; PINNED="${cfg.pinnedVersion}"; SECRET="${cfg.secretFile}"
    PROXY_ARGS=""
    if [ -n "${cfg.proxy}" ]; then
      if curl -s -o /dev/null --max-time 3 -x "${cfg.proxy}" https://github.com 2>/dev/null; then
        PROXY_ARGS="-c http.proxy=${cfg.proxy} -c https.proxy=${cfg.proxy}"
      else
        echo "dsh: 代理 ${cfg.proxy} 不可达，回退直连"
      fi
    fi
    NODE="${pkgs.nodejs}/bin/node"
    PNPM="${pnpm}/bin/pnpm"
    PATCH="${patchFile}"
    MARKER="${marker}"
    # 构建指纹 = 锁定版本 + 补丁内容 hash：
    # 只有这两者之一变化才重新编译，普通 flake 改动 / nixpkgs 升级 / 反复 switch 都跳过
    FINGERPRINT="''${REV}-$(sha256sum "$PATCH" | cut -d' ' -f1)"

    echo "dsh: DeepSeek Harness 安装/更新（flake 锁定版本: ''${PINNED}）"
    mkdir -p "$LAB"

    # 1. 克隆（完整 clone，方便 checkout 任意 rev）
    if [ ! -d "$REPO/.git" ]; then
      echo "dsh: 克隆仓库..."
      git $PROXY_ARGS clone https://github.com/deepseek-ai/deepseek-harness.git "$REPO" \
        || { echo "⚠️ dsh: clone 失败（网络/代理？）；可稍后重试 home-switch"; exit 1; }
    fi

    cd "$REPO"

    # 浅克隆先补全历史（后续 fetch 任意 commit 需要）
    if [ -f .git/shallow ]; then
      echo "dsh: 浅克隆补全历史..."
      git $PROXY_ARGS fetch --unshallow origin || true
    fi

    # 2. 固定版本：rev 已在本地直接 checkout（不联网、不 fetch，反复 switch 无网络开销）；
    #    缺失才从 origin 获取（分支名也走这里）
    if ! git cat-file -e "$REV^{commit}" 2>/dev/null; then
      echo "dsh: 本地无 rev=''${REV}，从 origin 获取..."
      git $PROXY_ARGS fetch origin "$REV" \
        || { echo "⚠️ dsh: 无法获取 rev=''${REV}（检查 gitRev / 网络 / 代理）"; exit 1; }
    fi
    git checkout -f "$REV" \
      || { echo "⚠️ dsh: checkout 失败 rev=''${REV}"; exit 1; }

    CURRENT="$(git rev-parse HEAD)"

    if [ "$CURRENT" != "$PINNED" ]; then
      echo "⚠️ dsh: checkout=''${CURRENT} ≠ flake 锁定=''${PINNED}（gitRev 被覆盖为分支/其它 commit；要固定版本请用默认值）"
    fi

    # 3. 打补丁（若上游已修复则跳过）
    if ! grep -q "dsh-client-ui-directory-picker-native" tsconfig.base.json; then
      if git apply --check "$PATCH" 2>/dev/null; then
        git apply "$PATCH"
        echo "dsh: 已应用 tsconfig 补丁"
      else
        echo "⚠️ dsh: tsconfig 补丁无法应用（上游可能已修复或结构变化），请手动检查"
      fi
    fi

    # 4. 构建：仅当版本/补丁指纹变化或产物缺失时才执行
    NEED_BUILD=0
    [ -f "$MARKER" ] || NEED_BUILD=1
    [ "$(cat "$MARKER" 2>/dev/null)" = "$FINGERPRINT" ] || NEED_BUILD=1
    [ -d node_modules ] || NEED_BUILD=1
    [ -f apps/cli/lib/bin.js ] || NEED_BUILD=1
    if [ "$NEED_BUILD" = 1 ]; then
      echo "dsh: 版本/补丁变化或产物缺失，pnpm install + build（首次约 2-3 分钟）..."
      "$PNPM" install || { echo "⚠️ dsh: pnpm install 失败"; exit 1; }
      "$PNPM" run build || { echo "⚠️ dsh: build 失败"; exit 1; }
      echo "$FINGERPRINT" > "$MARKER"
    else
      echo "dsh: ''${CURRENT} 已构建（本 flake 锁定版本未变），跳过编译"
    fi

    # 5. 写 DeepSeek API key（来自 agenix 解密后的 secret；缺失则跳过，可在 Web UI 填）
    if [ -r "$SECRET" ]; then
      mkdir -p "$DSH"
      umask 077
      printf 'DEEPSEEK_API_KEY: %s\n' "$(cat "$SECRET")" > "$DSH/.credentials.yaml"
      echo "dsh: 已写入凭据 $DSH/.credentials.yaml"
    else
      echo "dsh: 未找到 ''${SECRET}，跳过凭据写入（Web UI 设置→模型 里手动填）"
    fi

    echo "dsh: 完成。启动：~/dsh-lab/dsh-web.sh start"
  '';

  # 清理脚本：关掉开关后删除全部痕迹
  cleanupScript = pkgs.writeShellScript "dsh-cleanup" ''
    echo "dsh: 清除 DeepSeek Harness..."
    export PATH="${pkgs.git}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    pkill -f "apps/cli/src/bin.ts web" 2>/dev/null || true
    rm -rf "${repo}" "${dshHome}"
    rm -f "${labDir}/web.log" "${labDir}/dsh-web.sh"
    rmdir "${labDir}" 2>/dev/null || true
    echo "dsh: 已清除"
  '';

  # ~/dsh-lab/dsh-web.sh 启停脚本
  launcherText = ''
    #!/usr/bin/env bash
    # DeepSeek Harness Web UI 启停脚本（由本模块生成，勿手改）
    # 用法: dsh-web.sh start|stop|status|restart
    set -euo pipefail
    REPO="${repo}"; URL="http://127.0.0.1:${toString cfg.port}"; LOG="${logFile}"
    start() {
      if curl -s -o /dev/null "$URL/"; then echo "已运行: $URL"; return 0; fi
      cd "$REPO"
      DSH_TELEMETRY_DISABLED=1 nohup ${pkgs.nodejs}/bin/node --expose-internals --import tsx/esm \
        apps/cli/src/bin.ts web --host 127.0.0.1 --port ${toString cfg.port} > "$LOG" 2>&1 &
      echo "启动中 (pid $!)... 日志: $LOG"
      for i in $(seq 1 30); do sleep 1; if curl -s -o /dev/null "$URL/"; then
        echo "✓ 就绪: $URL"; return 0; fi; done
      echo "✗ 启动失败，日志尾部:"; tail -20 "$LOG"; return 1
    }
    stop()   { pkill -f "apps/cli/src/bin.ts web" 2>/dev/null && echo "已停止" || echo "未在运行"; }
    status() { if curl -s -o /dev/null "$URL/"; then echo "运行中: $URL"; else echo "未运行"; fi; }
    case "''${1:-}" in
      start) start ;;
      stop) stop ;;
      status) status ;;
      restart) stop; sleep 1; start ;;
      *) echo "用法: $0 start|stop|status|restart"; exit 1 ;;
    esac
  '';
in
{
  options.programs.deepseekHarness = {
    enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "启用 DeepSeek Harness（后台服务克隆+构建；关闭即删除 ~/deepseek-harness 与 ~/.dsh）。默认关闭，只在目标主机显式开启";
    };
    startAtBoot = lib.mkOption {
      type = types.bool;
      default = false;
      description = "登录后自动启动 Web UI（Linux: systemd user 服务；macOS: LaunchAgent）";
    };
    gitRev = lib.mkOption {
      type = types.str;
      default = pinnedRev;
      description = ''
        deepseek-harness checkout 的 commit。默认 = 本 flake 锁定的版本
        （flake.lock 的 deepseek-harness 输入，${pinnedRev}）：只有显式更新该
        flake 输入（nix flake lock --update-input deepseek-harness）才会变，
        否则反复 home-switch / 改其它配置都不会重建 dsh。
        改成分支名（如 "master"）可追踪上游最新，但上游每次变动都会触发重新编译。
      '';
    };
    pinnedVersion = lib.mkOption {
      type = types.str;
      readOnly = true;
      internal = true;
      default = pinnedRev;
      description = "本 flake 锁定的 dsh 版本（flake.lock 中 deepseek-harness 输入的 rev）";
    };
    secretFile = lib.mkOption {
      type = types.str;
      default = "/run/agenix/deepseek-api-key";
      description = "DeepSeek API key 来源（agenix 解密路径）；不存在则跳过，改为 Web UI 手动填";
    };
    proxy = lib.mkOption {
      type = types.str;
      default = "";
      description = "git 代理（如 http://127.0.0.1:7897），空 = 直连";
    };
    port = lib.mkOption {
      type = types.port;
      default = 3080;
      description = "Web UI 监听端口";
    };
  };

  config = lib.mkMerge [
    # 启用：装依赖、生成启停脚本、安装/更新仓库、注册服务
    (lib.mkIf cfg.enable {
      home.packages = [
        pkgs.nodejs # dsh 运行时（npm 源插件也要用）
        pnpm # 安装/构建（版本保障见 lib/pnpm.nix）
        pkgs.git
        pkgs.curl
      ];

      home.file."dsh-lab/dsh-web.sh" = {
        text = launcherText;
        executable = true;
      };

      # 安装/更新：后台 oneshot 服务，激活只触发不阻塞。
      # （首次 clone + pnpm install + build 远超 systemd 5 分钟激活超时，同步跑会被杀）
      systemd.user.services.dsh-setup = lib.mkIf pkgs.stdenv.isLinux {
        Unit = {
          Description = "DeepSeek Harness 安装/更新（后台）";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          Type = "oneshot";
          TimeoutStartSec = 0; # 不限时
          ExecStart = toString setupScript;
        };
        Install.WantedBy = [ "default.target" ]; # 登录时也会跑（marker 幂等）
      };

      home.activation.deepseekHarness = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        if pkgs.stdenv.isLinux then
          ''
            systemctl --user start --no-block dsh-setup.service 2>/dev/null || \
              echo "dsh: 未能后台触发安装（登录后 dsh-setup.service 会自动运行）"
            echo "dsh: 已后台触发安装/更新，查看进度: journalctl --user -u dsh-setup -f"
          ''
        else
          ''
            echo "dsh: 后台触发安装/更新（日志: ${logFile}）"
            (nohup ${setupScript} >>"${logFile}" 2>&1 &)
          ''
      );

      # Linux: systemd user 服务（startAtBoot 才开机自启，否则用 dsh-web.sh 手动启停）
      systemd.user.services.dsh-web = lib.mkIf pkgs.stdenv.isLinux {
        Unit = {
          Description = "DeepSeek Harness Web UI";
          After = [
            "network-online.target"
            "dsh-setup.service"
          ];
          Wants = [ "dsh-setup.service" ];
        };
        Service = {
          Type = "simple";
          ExecStart = startCmd;
          Restart = "on-failure";
          RestartSec = 3;
        };
        Install.WantedBy = lib.mkIf cfg.startAtBoot [ "default.target" ];
      };

      # macOS: LaunchAgent（RunAtLoad = startAtBoot；手动启动：launchctl kickstart gui/$(id -u)/org.nix-community.home-manager.dsh-web）
      launchd.agents.dsh-web = lib.mkIf pkgs.stdenv.isDarwin {
        enable = true;
        config = {
          ProgramArguments = [ (toString startCmd) ];
          RunAtLoad = cfg.startAtBoot;
          KeepAlive = false;
          ProcessType = "Background";
          StandardOutPath = logFile;
          StandardErrorPath = logFile;
        };
      };
    })

    # 关闭开关：激活时清除所有痕迹
    (lib.mkIf (!cfg.enable) {
      home.activation.deepseekHarness = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        if pkgs.stdenv.isLinux then
          ''
            systemctl --user stop dsh-setup.service dsh-web.service 2>/dev/null || true
          ''
          + toString cleanupScript
        else
          toString cleanupScript
      );
    })
  ];
}
