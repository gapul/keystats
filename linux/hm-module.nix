# home-manager module: the collector as a systemd user service, and optionally linux.json.
#
#   imports = [ "${keystatsSrc}/linux/hm-module.nix" ];
#   services.keystats = {
#     enable = true;
#     settings.language = "en";
#   };
#
# With settings set, linux.json is a symlink into the Nix store: the daemon still reloads it on
# change, and the GUI shows the settings without letting them be saved. Leave settings at null
# to keep editing them in the GUI.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.keystats;
  inherit (lib) mkOption types;
in
{
  options.services.keystats = {
    enable = lib.mkEnableOption "the KeyStats keyboard statistics collector";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The keystats-linux package.";
    };

    # Defaults mirror Config::default() in src/config.rs, so an empty attrset writes the same
    # file the GUI would.
    settings = mkOption {
      default = null;
      description = "Contents of ~/.config/keystats/linux.json. null leaves the file to the GUI.";
      type = types.nullOr (
        types.submodule {
          options = {
            language = mkOption {
              type = types.enum [
                "ja"
                "en"
              ];
              default = "ja";
              description = "GUI language.";
            };
            layout = mkOption {
              type = types.enum [
                "ansi"
                "jis"
              ];
              default = "ansi";
              description = "Keyboard layout drawn in the heatmap.";
            };
            excluded_apps = mkOption {
              type = types.listOf types.str;
              default = [
                "org.keepassxc.KeePassXC"
                "Bitwarden"
                "1Password"
              ];
              description = "Application IDs never recorded (case-insensitive).";
            };
            excluded_devices = mkOption {
              type = types.listOf types.str;
              default = [ "Espanso" ];
              description = "Input device names never opened.";
            };
            input_mode = mkOption {
              type = types.enum [
                "auto"
                "physical"
                "xremap"
              ];
              default = "auto";
              description = "auto picks xremap's virtual keyboard when present, physical keyboards otherwise.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile."keystats/linux.json" = lib.mkIf (cfg.settings != null) {
      source = (pkgs.formats.json { }).generate "keystats-linux.json" cfg.settings;
    };

    systemd.user.services.keystats = {
      Unit = {
        Description = "KeyStats native keyboard statistics";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${lib.getExe cfg.package} daemon";
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0077";
        Nice = 10;
        NoNewPrivileges = true;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
