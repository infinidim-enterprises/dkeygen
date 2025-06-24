{ crystal
, gcc
, glibc
, bip39key
, runCommandNoCC
, remarshal_0_17
, lib
, staticBinary ? false
, staticLibs ? [ ]
}:
let
  inherit (lib // builtins)
    optionalAttrs
    fileContents
    nix-filter
    fromJSON;

  flags = {
    NIX_CFLAGS_COMPILE = [ "-pthread" ];
    NIX_LDFLAGS = [ "-lrt" ];
  };

  src = nix-filter {
    root = ../.;
    include = [
      "src"
      "shards.nix"
      "shard.lock"
      "shard.yml"
    ];
  };

  shardsFile = src + "/shards.nix";
  shard = fromJSON (fileContents (runCommandNoCC "version-from-shard"
    { nativeBuildInputs = [ remarshal_0_17 ]; }
    ''
      yaml2json ${src}/shard.yml $out
    ''));
  version = shard.version;
  pname = shard.name;
  format = if staticBinary then "crystal" else "shards";
  target = shard.targets.dkeygen.main;
in

crystal.buildCrystalPackage ((optionalAttrs staticBinary flags) // {
  inherit src shardsFile version pname format;

  nativeBuildInputs = [ gcc ];
  buildInputs = [ bip39key glibc glibc.dev ] ++ staticLibs;
  doInstallCheck = false;

  crystalBinaries.${pname} = {
    src = target;
    options = [
      "--static"
      "--release"
      "--no-debug"
      "--progress"
      "--verbose"
    ];
  };

  meta.mainProgram = pname;
  meta.license = lib.licenses.mit;
  meta.homepage = "https://github.com/infinidim-enterprises/dkeygen";
  meta.description = "Generate/Dump an OpenPGP key from a BIP39 mnemonic";
})
