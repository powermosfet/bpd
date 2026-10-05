{ pkgs, module, bpd }:
let
  python = pkgs.python3.withPackages (ps: [ ps.pika ps.requests ]);
in {
  name = "barcode-product-desk";
  nodes.machine = { ... }: {
    imports = [ module ];
    services.rabbitmq.enable = true;
    services.bpd = {
      enable = true;
      package = bpd;
      productUrl = "http://127.0.0.1:8003/api/product";
      claimTimeoutSeconds = 8;
      rabbitmq = { username = "bpd"; passwordFile = "/run/bpd-test-credential"; };
    };
    # Test-only credential; production uses a secret managed outside the store.
    systemd.tmpfiles.rules = [ "f /run/bpd-test-credential 0600 root root - test-password" ];
    environment.systemPackages = [ python pkgs.curl ];
    environment.etc."bpd-stub.py".source = ./stub.py;
    environment.etc."bpd-integration.py".source = ./integration.py;
    systemd.services.product-stub = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${python}/bin/python /etc/bpd-stub.py";
    };
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("rabbitmq.service")
    machine.wait_for_unit("product-stub.service")
    machine.succeed("runuser -u rabbitmq -- rabbitmqctl add_user bpd test-password")
    machine.succeed("runuser -u rabbitmq -- rabbitmqctl set_permissions -p / bpd '.*' '.*' '.*'")
    machine.wait_for_unit("bpd.service")
    machine.succeed("python /etc/bpd-integration.py")
  '';
}
