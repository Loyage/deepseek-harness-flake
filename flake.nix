{
  description = "DeepSeek Harness (dsh) home-manager 模块：后台克隆 + 构建的 dev-preview 测试工具";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, home-manager, ... }:
    let
      module = import ./modules/deepseek-harness.nix;
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
