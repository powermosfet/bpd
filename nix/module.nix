{ packageFor }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.bpd;
  runtimeConfig = pkgs.writeText "bpd-config.json" (builtins.toJSON {
    inherit (cfg) listenAddress listenPort productUrl claimTimeoutSeconds;
    rabbitmq = {
      inherit (cfg.rabbitmq) host port vhost username queue;
    };
  });
in {
  options.services.bpd = {
    enable = mkEnableOption "Barcode Product Desk";
    package = mkOption {
      type = types.package;
      default = packageFor pkgs;
      defaultText = lib.literalExpression "BPD package built with the system's Nixpkgs";
      description = "BPD package to run.";
    };
    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "HTTP bind address. Use a LAN address or reverse proxy for remote access.";
    };
    listenPort = mkOption { type = types.port; default = 8080; description = "HTTP listen port."; };
    productUrl = mkOption {
      type = types.str;
      default = "http://mook.local:8003/api/product";
      description = "Absolute REST URL receiving product JSON POST requests.";
    };
    claimTimeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 900;
      description = "Maximum claim duration before returning a barcode to RabbitMQ.";
    };
    rabbitmq = {
      host = mkOption { type = types.str; default = "localhost"; description = "RabbitMQ host."; };
      port = mkOption { type = types.port; default = 5672; description = "RabbitMQ AMQP port."; };
      vhost = mkOption { type = types.str; default = "/"; description = "RabbitMQ virtual host."; };
      username = mkOption { type = types.str; default = "bpd"; description = "RabbitMQ username."; };
      queue = mkOption { type = types.str; default = "missing-barcodes"; description = "Existing queue of missing barcodes."; };
      passwordFile = mkOption {
        type = types.str;
        description = "Absolute runtime path to the RabbitMQ password file. Do not use a Nix path literal or put the secret in the Nix store.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = lib.hasPrefix "/" cfg.rabbitmq.passwordFile && !(lib.hasPrefix builtins.storeDir cfg.rabbitmq.passwordFile);
      message = "services.bpd.rabbitmq.passwordFile must be an absolute runtime path outside the Nix store.";
    }];
    systemd.services.bpd = {
      description = "Barcode Product Desk";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} --config ${runtimeConfig} --rabbitmq-password-file %d/rabbitmq-password";
        LoadCredential = [ "rabbitmq-password:${cfg.rabbitmq.passwordFile}" ];
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 15;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        UMask = "0077";
      };
    };
  };
}
