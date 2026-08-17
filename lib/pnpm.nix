# pnpm 版本保障：上游 deepseek-harness 的 packageManager 字段要求 pnpm >= 11.7.0。
#
# 背景：pnpm 11.2.x 解析 pnpm-workspace.yaml 的 allowBuilds 里 file: 协议条目时会抛
# ERR_PNPM_INVALID_VERSION_UNION，11.7.0 起才支持 depPath 形式的条目。
# 因此这里对 nixpkgs 的 pnpm_11 做条件 override：
#   - 当前 nixpkgs 的 pnpm_11 已 >= 11.7.0（如 nixpkgs-unstable 的 11.20.0）→ 直接用
#   - 较旧的 nixpkgs（11.2.x 时代）→ override 到 11.7.0
# 模块内部自包含此逻辑，消费方无需额外 overlay，不管用哪个 nixpkgs 版本都能正确构建。
{ pkgs }:

let
  pnpm11 = pkgs.pnpm_11;
in
if builtins.compareVersions pnpm11.version "11.7.0" >= 0 then
  pnpm11
else
  pnpm11.overrideAttrs (old: {
    version = "11.7.0";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/pnpm/-/pnpm-11.7.0.tgz";
      hash = "sha256-3q+n7JihIYtqBHKJuS++I5XB4i00lbtxFlMBMhjuFe4=";
    };

    # nixpkgs 的 installCheck 硬编码了版本号，需同步
    installCheckPhase = ''
      runHook preInstallCheck
      tmp="$(mktemp -d)"
      mkdir -p "$tmp/home" "$tmp/project"
      printf '{"packageManager":"pnpm@11.99.99"}\n' > "$tmp/project/package.json"
      (
        cd "$tmp/project"
        version="$(HOME="$tmp/home" $out/bin/pnpm --version)"
        test "$version" = "11.7.0"
      )
      rm -rf "$tmp"
      runHook postInstallCheck
    '';

    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
      pkgs.makeWrapper
    ];

    postInstall = (old.postInstall or "") + ''
      wrapProgram $out/bin/pnpm \
        --set-default pnpm_config_minimum_release_age 0
      wrapProgram $out/bin/pnpx \
        --set-default pnpm_config_minimum_release_age 0
    '';
  })
