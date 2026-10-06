# Barcode Product Desk

BPD is a small Haskell web service for assigning descriptions to barcodes from a
RabbitMQ queue. It renders ordinary HTML pages and forms, with no JavaScript.
Products are saved through your existing REST service; BPD has no database.

## Use

Open BPD to see **Ready in queue**, then click **Fetch barcode**, enter the
product description, and click **Save product**. The home page offers **Resume**
while a barcode is being edited. **Return to queue** releases it without saving.
**Drop barcode** removes an unidentifiable barcode from the queue without saving
a product. Invalid messages can also be dropped.
Refreshing a page updates the counter; it excludes the barcode being edited.
One active claim is shared by all browser tabs in this single-operator service.

The queue must already exist. Messages are raw UTF-8 strings such as `786534249`
or `00012345`, without JSON quoting or trailing newlines. Leading zeros are
preserved. Empty, invalid UTF-8, quoted, whitespace-containing, or oversized
(over 256 characters) payloads display an error and remain recoverable through
return or expiry. Descriptions are trimmed and must contain 1–2000 characters.

BPD sends:

```http
POST /api/product
Content-Type: application/json

{"barcode":"00012345","description":"Milk"}
```

Only a `2xx` response allows acknowledgement. Redirects are not followed.
Failures retain the description while the claim remains live and offer an
explicit retry or return. REST requests time out after 10 seconds. Claims expire
15 minutes after fetching by default, even if a tab remains open; a save already
in progress completes before expiry is handled. Expired forms cannot save or
release newer claims.

## Build and run

```sh
nix build path:.#bpd
./result/bin/bpd --config config.example.json --rabbitmq-password-file /run/secrets/bpd-rabbitmq
```

Use `path:.` while working with untracked files. Once the source is tracked in
Git, `nix build .#bpd` works too. `nix run path:. -- --help` shows the command-line
interface. Copy and edit [config.example.json](config.example.json); omitted
settings use the defaults shown there, except the default RabbitMQ username is
`guest`. The password is read only from the separate file; a trailing line ending
is removed. Do not put passwords in configuration or the Nix store.

BPD binds to `127.0.0.1:8080` by default. For direct LAN access, set
`listenAddress` to the server's LAN IP and allow the port in your firewall.
There is no BPD login: deploy on your trusted LAN or behind your existing
access-controlled proxy. RabbitMQ uses AMQP on port 5672 by default, and the
product URL defaults to `http://mook.local:8003/api/product`. The runtime user
must be able to resolve that hostname.

RabbitMQ settings include `host`, `port`, `vhost`, `username`, and `queue`.
The queue defaults to `missing-barcodes`. BPD uses passive queue declarations
and reads/acknowledges messages; give its user RabbitMQ permissions sufficient
to inspect and consume that queue. It never creates queues, exchanges, or
bindings. The counter uses AMQP, so the RabbitMQ management plugin is unnecessary.
For a personal-network deployment the RabbitMQ connection is plain AMQP;
AMQPS support is not included in this version.

## NixOS

Add BPD as a flake input and import its module:

```nix
{
  inputs.bpd.url = "path:/path/to/bpd";

  outputs = { nixpkgs, bpd, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        bpd.nixosModules.default
        ({ ... }: {
          services.bpd = {
            enable = true;
            listenAddress = "127.0.0.1";
            listenPort = 8080;
            productUrl = "http://mook.local:8003/api/product";
            claimTimeoutSeconds = 900;
            rabbitmq = {
              host = "rabbitmq.local";
              port = 5672;
              vhost = "/";
              username = "bpd";
              queue = "missing-barcodes";
              passwordFile = "/run/secrets/bpd-rabbitmq";
            };
          };
        })
      ];
    };
  };
}
```

Provision `passwordFile` using your existing secret manager before the service
starts. It is a string runtime path, not a Nix path literal. systemd loads it
with `LoadCredential` for BPD's dynamic user. The module deliberately does not
open firewall ports or configure RabbitMQ, the product service, or a proxy.
You can override `services.bpd.package` with the flake's package; otherwise it
builds using your system's Nixpkgs Haskell package set.

The flake exports `packages.<system>.bpd`, `packages.<system>.default`,
`apps.<system>.default`, `devShells.<system>.default`, `nixosModules.bpd`, and
`nixosModules.default`. Supported package targets are `x86_64-linux` and
`aarch64-linux`.

## Reliability and operations

An active message stays unacknowledged on its original RabbitMQ channel. BPD
returns it on explicit release or expiry. Disconnects invalidate the form;
process death leaves the message eligible for broker redelivery. Reconnection
uses delays from 1 to 30 seconds. A queue inspection failure is shown as
**Unavailable**, never as an empty queue. The service can start before RabbitMQ
or the queue is available.

Delivery is **at least once**. A product may be saved even when its HTTP response
is lost, or BPD may crash after saving and before acknowledging. The current REST
service returns `500` for duplicate barcodes, so BPD keeps all such failures
pending. It never treats `500` or a future `409` as success automatically and
never retries product POSTs automatically. A lookup endpoint or idempotent save
contract will be needed to resolve uncertain saves automatically.

Queue durability, persistent publishing, broker acknowledgement timeouts, and
quorum-queue delivery limits remain properties of your RabbitMQ deployment.
Configure its acknowledgement timeout above BPD's claim duration plus the save
request timeout. Repeatedly returning poison messages may reach a broker delivery
limit; configure dead-letter handling where needed.

`GET /healthz` reports that the HTTP process is running. `GET /readyz` checks
RabbitMQ queue access and returns `503` if unavailable; it does not probe the
product endpoint. Service output goes to the journal:

```sh
journalctl -u bpd
```

## Development and checks

```sh
nix develop path:.
cabal test
nix flake check path:.
```

The package build runs Hspec tests for claim lifecycle, validation, concurrent
submissions, CSRF verification, stale forms, and HTML escaping. The flake also
includes a NixOS VM integration check with real RabbitMQ, a stub REST service,
and the systemd module. It tests successful saves, `500` responses, timeouts,
expiry, return, disconnects, and crash redelivery. VM checks need a Linux host
with virtualization available; each package target must be built on a matching
host or a configured remote builder/emulator.

When changing Cabal dependencies, update `nix/package.nix` alongside `bpd.cabal`.
The explicit dependency mapping lets both architectures evaluate without
building a Cabal-to-Nix generator during evaluation.
