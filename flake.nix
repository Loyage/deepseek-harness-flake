{
  description = "DeepSeek Harness (dsh) home-manager 模块：后台克隆 + 构建的 dev-preview 测试工具";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # dsh 版本锁（flake = false：只取 rev，不当作 flake）。
    # 安装/重建的 dsh 版本 = 这里锁定的 commit（写入本 flake 的 flake.lock）。
    # 升级 dsh 的唯一途径：改下面 url 的 rev 后执行
    #   nix flake lock --update-input deepseek-harness
    # 然后重新 home-switch（dsh-setup 会自动 fetch/checkout/重编译）。
    deepseek-harness = {
      url = "github:deepseek-ai/deepseek-harness/47f943859bef60e4160492346772ded9b24f765a";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      deepseek-harness,
      ...
    }:
    let
      # flake.lock 锁定的 dsh 版本（git 输入携带 rev 元数据）
      pinnedRev = deepseek-harness.rev;
      module = (import ./modules/deepseek-harness.nix) { inherit pinnedRev; };
    in
    {
      homeModules = {
        default = module;
        deepseek-harness = module;
      };

      # 冒烟测试：x86_64-linux 上以 enable = true 求值并构建激活脚本，
      # 验证选项类型、pnpm 版本保障（lib/pnpm.nix）、systemd/launchd 分支都正确。
      checks."x86_64-linux".default =
        (home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs { system = "x86_64-linux"; };
          modules = [
            module
            {
              home.username = "dsh-test";
              home.homeDirectory = "/home/dsh-test";
              home.stateVersion = "26.11";
              programs.deepseekHarness.enable = true;
            }
          ];
        }).activationPackage;
    };
}
