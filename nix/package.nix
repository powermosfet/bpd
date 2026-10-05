# Cabal dependency mapping, kept explicit so flake evaluation needs no builds.
# Update alongside bpd.cabal when changing dependencies.
{ mkDerivation, aeson, amqp, async, base, bytestring, cookie, hspec
, http-client, http-client-tls, http-types, lib, lucid, scotty
, text, time, unix, uuid, wai, wai-extra, warp, src
}:
mkDerivation {
  pname = "bpd";
  version = "0.1.0.0";
  inherit src;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson amqp async base bytestring cookie http-client http-client-tls
    http-types lucid scotty text time uuid wai warp
  ];
  executableHaskellDepends = [ async base unix warp ];
  testHaskellDepends = [
    aeson async base bytestring hspec http-types text time wai wai-extra
  ];
  description = "Server-rendered desk for resolving missing product barcodes";
  license = lib.licenses.bsd3;
  mainProgram = "bpd";
}
