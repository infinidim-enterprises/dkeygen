{
  description = "(BIP39 mnemonic) Generate and/or Dump to OpenPGP card an ed25519 key";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.nixago.url = "github:jmgilman/nixago";
  inputs.nixago.inputs.nixpkgs.follows = "nixpkgs";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.devshell.url = "github:numtide/devshell";
  inputs.nvfetcher.url = "github:berberman/nvfetcher/0.7.0";
  inputs.nix-filter.url = "github:numtide/nix-filter";

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , devshell
    , nvfetcher
    , nixago
    , nix-filter
    , ...
    }:

    let
      inherit (nixpkgs.lib // builtins)
        composeManyExtensions
        concatMapStringsSep
        makeLibraryPath
        splitString
        attrValues
        findFirst
        optional
        isString
        hasInfix
        filter;

      nixago_config = attrValues {
        githubsettings = {
          format = "yaml";
          output = ".github/settings.yml";
          hook.mode = "copy";
          data = {
            repository = {
              name = "dkeygen";
              inherit (import (self + /flake.nix)) description;
              # homepage = "CONFIGURE-ME";
              # topics = "crystal-lang";
              default_branch = "master";
              allow_squash_merge = true;
              allow_merge_commit = true;
              allow_rebase_merge = false;
              delete_branch_on_merge = true;
              private = false;
              has_issues = true;
              has_projects = false;
              has_wiki = false;
              has_downloads = true;
            };
            labels = [
              { name = "bug"; color = "#CC0000"; description = "An issue with the system 🐛."; }
              { name = "feature"; color = "#336699"; description = "New functionality."; }
            ];
          };
        };
        release = {
          output = ".github/workflows/release.yaml";
          format = "yaml";
          hook.mode = "copy";
          data = {
            name = "Release";
            on.push = null;
            on.workflow_dispatch = null;
            jobs.make_release_bin = {
              runs-on = "\${{ matrix.runs-on }}";
              strategy.matrix.include = [
                { runs-on = "ubuntu-22.04"; arch = "x86_64-linux"; }
                { runs-on = "ubuntu-22.04-arm"; arch = "aarch64-linux"; }
              ];

              steps = [
                {
                  name = "⬆ Checkout";
                  uses = "actions/checkout@v4";
                }
                {
                  name = "✓ Install Nix";
                  uses = "cachix/install-nix-action@v31";
                  "with" = {
                    nix_path = "nixpkgs=channel:nixos-unstable";
                    extra_nix_config = ''
                      access-tokens = github.com=''${{ secrets.GITHUB_TOKEN }}
                      experimental-features = nix-command flakes impure-derivations auto-allocate-uids cgroups
                      system-features = nixos-test benchmark big-parallel kvm recursive-nix
                      download-buffer-size = 104857600
                      accept-flake-config = true
                    '';
                  };
                }
                {
                  name = "✓ Install cachix";
                  uses = "cachix/cachix-action@v16";
                  "with" = {
                    name = "njk";
                    extraPullNames = "nix-community, njk";
                    authToken = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
                    signingKey = "\${{ secrets.CACHIX_SIGNING_KEY }}";
                    cachixArgs = "--compression-level 9";
                  };
                }
                {
                  name = "✓ Build package";
                  run = ''nix build --accept-flake-config .#default'';
                  "if" = "github.ref_type != 'tag'";
                }
                {
                  name = "✓ Build release";
                  run = ''
                    working_dir=$(pwd)
                    build_loc="$working_dir/release.txt"
                    nix build --accept-flake-config --json .#default | jq -r '.[] | .outputs | (.out + "/bin/dkeygen")' > "$build_loc"
                    cp "$(cat $build_loc)" "$working_dir/dkeygen-$(uname -m)"
                  '';
                  "if" = "github.ref_type == 'tag'";
                }
                {
                  name = "✓ Release";
                  uses = "softprops/action-gh-release@v2";
                  "if" = "github.ref_type == 'tag'";
                  "with" = {
                    files = ''dkeygen-*'';
                  };
                }
                {
                  name = "✓ tmate.io session";
                  uses = "mxschmitt/action-tmate@master";
                  "if" = "\${{ failure() }}";
                  "with" = {
                    # detached = true;
                    connect-timeout-seconds = 60 * 10;
                    limit-access-to-actor = true;
                  };
                }
              ];
            };
          };
        };
      };
    in

    flake-utils.lib.eachDefaultSystem
      (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = (attrValues self.overlays) ++ [
            devshell.overlays.default
            nvfetcher.overlays.default
          ];
        };

        pkgs_clean = import nixpkgs {
          inherit system;
        };

        mkbin = pkgs.writeShellApplication {
          name = "mkbin";
          text = ''
            crystal build "$PRJ_ROOT/src/dkeygen.cr" --static \
              --release \
              --no-debug \
              --progress \
              --threads "$(nproc)"
          '';
        };

        mkdebugbin = pkgs.writeShellApplication {
          name = "mkdebugbin";
          text = ''
            crystal build "$PRJ_ROOT/src/dkeygen.cr" --static \
              --debug \
              --progress \
              --threads "$(nproc)"
          '';
        };

        repl = pkgs.writeShellApplication {
          name = "repl";
          runtimeInputs = [ pkgs.nixVersions.latest ];
          text = ''
            nix repl --show-trace --extra-experimental-features impure-derivations --file "$PRJ_ROOT/nix/repl.nix"
          '';
        };

        update-sources = pkgs.writeShellApplication {
          name = "update-sources";
          runtimeInputs = [ pkgs.nvfetcher-bin ];
          text = ''
            nvfetcher -j 0 --timing --build-dir "$PRJ_ROOT/nix/sources" --config "$PRJ_ROOT/nix/sources/nvfetcher.toml" --keep-old
          '';
        };

        update-shards = pkgs.writeShellApplication {
          name = "update-shards";
          runtimeInputs = with pkgs; [
            shards
            crystal2nix
          ];
          text = ''
            _update() {
              local dir
              dir="''${1}"

              cd "''${dir}"

              shards update
              crystal2nix

              rm -rf "''${dir:?}/lib"
            }

            _update "''${PRJ_ROOT:?}"

            cp --force ${pkgs.sources.crystalline.src}/shard.yml "$PRJ_ROOT/nix/packages/crystalline"
            _update "$PRJ_ROOT/nix/packages/crystalline"
          '';
        };

        withStatic = drv: drv.overrideAttrs
          (o: {
            configureFlags =
              let
                flags = o.configureFlags or [ ];
                needsStatic =
                  !isString (findFirst (hasInfix "static") false flags) &&
                  drv.pname != "openssl";
              in
              flags ++ optional needsStatic "--enable-static";
          });

        staticLibs = (map withStatic (with pkgs.pkgsMusl; [
          stdenv.cc.libc
          libffi.dev
          zlib.dev
          pcre2.dev
          libxml2.dev
          ((openssl.override { static = true; }).dev)
          libevent.dev
          boehmgc.dev
          libyaml.dev

          gmp.dev
          libz.dev
        ]));

        libs = makeLibraryPath staticLibs;
        pkgconfigs = concatMapStringsSep ":" (s: s + "/pkgconfig") (splitString ":" libs);
      in
      {
        packages.default = self.packages.${system}.dkeygen-static;
        packages.dkeygen = pkgs.callPackage ./nix/default.nix { inherit (pkgs_clean) crystal; };
        packages.dkeygen-static = pkgs.pkgsMusl.callPackage ./nix/default.nix {
          inherit staticLibs;
          inherit (pkgs_clean) remarshal_0_17;
          staticBinary = true;
        };

        apps.${system}.dkeygen = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/dkeygen";
        };

        devShells.default = pkgs.devshell.mkShell {
          name = "dkeygen";
          devshell.startup.nixago_setup.text = (nixago.lib.${system}.makeAll nixago_config).shellHook;
          packages = with pkgs; [
            ameba
            pkgsMusl.shards
            crystal
            crystalline
            crystal2nix

            coreutils
            binutils
            # libsodium
            pkg-config

            bip39key
            gnupg
          ];

          env = [
            { name = "PRJ_DATA_DIR"; eval = "$XDG_CACHE_HOME/$name"; }
            # { name = "GNUPGHOME"; eval = "$PRJ_DATA_DIR/gnupg"; }
            { name = "SHARDS_INSTALL_PATH"; eval = "$PRJ_DATA_DIR/shards"; }
            { name = "SHARDS_BIN_PATH"; eval = "$SHARDS_INSTALL_PATH/.bin"; }
            { name = "PATH"; prefix = "$SHARDS_BIN_PATH"; }
            { name = "SHARDS_CACHE_PATH"; eval = "$SHARDS_INSTALL_PATH/.cache"; }
            { name = "CRYSTAL_PATH"; eval = "$SHARDS_INSTALL_PATH:$(crystal env CRYSTAL_PATH)"; }
            { name = "CRYSTAL_CACHE_DIR"; eval = "$SHARDS_INSTALL_PATH/.cache-crystal"; }
            { name = "LIBRARY_PATH"; eval = "${libs}:$LIBRARY_PATH"; }
            { name = "PKG_CONFIG_PATH"; eval = "${pkgconfigs}:$PKG_CONFIG_PATH"; }
          ];

          commands = [
            {
              package = mkdebugbin;
              help = "compile a debug binary";
            }

            {
              package = mkbin;
              help = "compile a static binary";
            }

            {
              package = repl;
              help = "nix repl with flake pkgs, lib and some helpers";
            }

            {
              package = update-sources;
              help = "Update sources with nvfetcher";
            }

            {
              package = update-shards;
              help = "Update shard.lock and shards.nix";
            }
          ];

        };
      }) //
    {
      # overlays.default = composeManyExtensions (with self.overlays; [
      #   (final: prev: { dkeygen = final.callPackage ./nix/default.nix { }; })
      # ]);
      overlays.sources = final: prev: {
        sources = final.callPackage ./nix/sources/generated.nix { };
      };
      overlays.bip39key = final: prev: {
        bip39key = final.callPackage ./nix/packages/bip39key { };
      };
      overlays.crystalline = final: prev: {
        crystalline = prev.crystalline.overrideAttrs (old: {
          inherit (final.sources.crystalline) src version;
          nativeBuildInputs = old.nativeBuildInputs or [ ] ++ [ final.shards ];
          shardsFile = ./nix/packages/crystalline/shards.nix;
        });
      };
      overlays.crystal = final: prev: {
        crystal = prev.pkgsMusl.crystal.overrideAttrs (old: {
          enableParallelBuilding = true;
          # ISSUE https://github.com/NixOS/nixpkgs/pull/380842
          # preCheck = old.preCheck + "\n" + "export LD_LIBRARY_PATH=${lib.makeLibraryPath nativeCheckInputs}:$LD_LIBRARY_PATH"
          buildInputs =
            let
              remove_openssl = filter (e: e.pname or "" != "openssl") old.buildInputs;
            in
            remove_openssl ++ (with final.pkgsMusl; [ libffi openssl ]);

          nativeBuildInputs = old.nativeBuildInputs or [ ] ++ [ final.pkgsMusl.openssl ];
          CRYSTAL_LIBRARY_PATH = "${final.pkgsMusl.openssl.out}/lib";
          CRYSTAL_INCLUDE_PATH = "${final.pkgsMusl.openssl.dev}/include";

          # old.buildInputs or [ ] ++ (with final; [ libffi ]);
          makeFlags = old.makeFlags or [ ] ++ [ "interpreter=1" ];
        });
      };
      overlays.nix-filter = _: prev: { lib = prev.lib // { nix-filter = nix-filter.lib; }; };
      overlays.crystal2nix = final: prev: {
        crystal2nix = prev.crystal2nix.overrideAttrs (_: {
          inherit (final.sources.crystal2nix) src;
        });
      };
    };
}
