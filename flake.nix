{
  description = "Slack's developer CLI, built from source at a pinned release, installed as slack-cli";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  # Offered, not imposed. Nix applies these only for a trusted user, and
  # otherwise says it is ignoring them. See the README for setting the
  # substituter in a NixOS configuration instead, which is what most people
  # actually want.
  nixConfig = {
    extra-substituters = [ "https://danielbodart.cachix.org" ];
    extra-trusted-public-keys = [
      "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
    ];
  };

  outputs =
    { self, nixpkgs }:
    let
      # The two Linux architectures CI builds and runs on. Slack publishes
      # macOS and Windows builds too, and Go would cross-compile to them, but
      # nothing here would ever test them.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Apache-2.0, so no allowUnfree, unlike the other danielbodart
      # repackagings: plain nixpkgs is enough.
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      overlay = final: prev: {
        slack-cli = final.callPackage ./package.nix { };
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          slack-cli = (pkgsFor system).callPackage ./package.nix { };
        in
        {
          inherit slack-cli;
          default = slack-cli;
        }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.slack-cli;
        slack-cli = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.slack-cli;
          meta.description = "Run the Slack CLI";
        };
      });

      # `nix flake check` builds these. The package build runs upstream's own
      # unit tests against the source it compiled, so a green check is more
      # than "it linked".
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          slack-cli = self.packages.${system}.slack-cli;
        in
        {
          inherit slack-cli;

          # The binary has to say the version sources.json pins, through the
          # wrapper, under its own name. That is three things at once: the
          # ldflags reached internal/version (otherwise it is v0.0.0-dev and
          # every command nags about an update), the wrapper runs, and argv[0]
          # survives it (otherwise the CLI calls itself .slack-cli-wrapped).
          version-matches-pin = pkgs.runCommand "slack-cli-version-matches-pin" { } ''
            export HOME="$TMPDIR"
            actual="$(${pkgs.lib.getExe slack-cli} --version)"
            expected="Using slack-cli v${slack-cli.version}"
            if [ "$actual" != "$expected" ]; then
              echo "expected '$expected', got '$actual'" >&2
              exit 1
            fi
            echo "$actual" >$out
          '';

          # A static Go binary should close over almost nothing: itself, and
          # the C wrapper in front of it with the glibc that wrapper links,
          # which every system already has. A Go toolchain in the closure
          # means a store path leaked into the binary (the usual culprit is a
          # GOROOT or -trimpath regression), and it would cost every consumer
          # a few hundred MiB. bash means the wrapper became a shell script.
          closure-is-slim =
            pkgs.runCommand "slack-cli-closure-is-slim"
              {
                closure = pkgs.closureInfo { rootPaths = [ slack-cli ]; };
                maxMiB = 96;
              }
              ''
                bad=$(grep -E -- '-(go-[0-9]|bash-[0-9])' "$closure/store-paths" || true)
                if [ -n "$bad" ]; then
                  echo "unwanted paths in the slack-cli closure:" >&2
                  echo "$bad" >&2
                  exit 1
                fi

                total=$(( $(cat "$closure/total-nar-size") / 1048576 ))
                echo "closure is $total MiB"
                if [ "$total" -gt "$maxMiB" ]; then
                  echo "closure is $total MiB, over the $maxMiB MiB budget" >&2
                  exit 1
                fi
                echo "$total MiB" >$out
              '';

          shellcheck = pkgs.runCommand "slack-cli-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${./scripts/update.sh}
            touch $out
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              curl
              jq
              nixfmt
              shellcheck
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
