{ flakePath ? (builtins.getEnv "PRJ_ROOT") }:
let
  flake = getFlake (toString flakePath);

  inherit (builtins)
    toString
    getFlake
    attrValues
    currentSystem;

  pkgs = import flake.inputs.nixpkgs {
    system = currentSystem;
    overlays = attrValues flake.overlays;
    config.allowUnfree = true;
  };

  inherit (pkgs) lib;
  inherit (lib) genAttrs;

  formats =
    genAttrs [
      "cdn"
      "elixirConf"
      "gitIni"
      "hocon"
      "ini"
      "iniWithGlobalSection"
      "javaProperties"
      "json"
      "keyValue"
      "libconfig"
      "lua"
      "php"
      "pythonVars"
      "toml"
      "xml"
      "yaml"
    ]
      (format: (pkgs.formats.${format} { }).generate);
in
{
  inherit
    flake
    pkgs
    formats;

  inherit (pkgs)
    writeScript
    writeScriptBin
    writeShellApplication
    writeShellScript
    writeShellScriptBin
    writeText
    writeTextDir
    writeTextFile
    writers;
} // (lib // builtins)
