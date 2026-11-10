{
  lib,
  buildPackages,
  buildGoModule,
  fetchFromGitHub,
  makeBinaryWrapper,
  gitMinimal,
  runtimeShell,
  sources ? lib.importJSON ./sources.json,
}:

let
  # Upstream's go.mod names the Go it needs, and it moves to a new minor
  # release well before nixpkgs makes that the default `go`. Building with
  # anything older fails outright: a go.mod newer than the toolchain is an
  # error under GOTOOLCHAIN=local, which the Nix sandbox needs because it has
  # no network to fetch a newer toolchain with. So scripts/update.sh copies
  # the minor version out of go.mod into sources.json, and this picks the
  # matching go_1_NN, from buildPackages because the compiler runs on the
  # build machine.
  goAttr = "go_" + lib.replaceStrings [ "." ] [ "_" ] sources.go;
  go =
    buildPackages.${goAttr}
      or (throw "slack-cli ${sources.version} needs Go ${sources.go}, and this nixpkgs has no ${goAttr}");
in
(buildGoModule.override { inherit go; }) (finalAttrs: {
  pname = "slack-cli";
  inherit (sources) version vendorHash;

  # By commit, not by tag. The updater resolves the tag once and records the
  # commit it pointed at, so the pin means the same tree even if upstream
  # later moves or deletes the tag, and the hash is there to prove it.
  src = fetchFromGitHub {
    owner = "slackapi";
    repo = "slack-cli";
    inherit (sources) rev hash;
  };

  # main.go is the module's only main package, at its root, so `go install`
  # names the binary after the module, github.com/slackapi/slack-cli:
  # slack-cli, not the `slack` that upstream's Makefile and goreleaser rename
  # it to. That is the name this package wants anyway, see the wrapper below.
  # subPackages is left unset so that the check phase runs the tests of every
  # package, not just of main.

  # Upstream's release builds for Linux are CGO_ENABLED=0 (.goreleaser.yml),
  # which gives a static binary that links nothing, not even glibc. Same here,
  # so what this builds behaves like what Slack ships, and the closure is the
  # binary and the wrapper and nothing else.
  env.CGO_ENABLED = 0;

  # The Makefile's LDFLAGS, which is how `slack version` knows what it is:
  # without it, it reports v0.0.0-dev and nags that every release is newer.
  # Upstream takes the value from `git describe`, which on a release tag is
  # the tag itself, so "v" + version is the same string. -s -w as in its CI
  # build; buildGoModule would strip the binary anyway.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/slackapi/slack-cli/internal/version.Version=v${finalAttrs.version}"
  ];

  nativeBuildInputs = [ makeBinaryWrapper ];

  # Upstream's unit tests, all of them, against the source that was built.
  # They need a writable home for the CLI's config directory and nothing from
  # the network. The self-update tests stand in fake slack binaries written
  # as #!/bin/bash scripts, which the sandbox does not have; they get a real
  # bash instead, in the test source only, so it is not in the closure. The
  # code they test is the self-update this package turns off, but it is
  # cheaper to keep them running than to keep a list of skips current.
  # `slack doctor`'s tests expect a git to report the version of.
  nativeCheckInputs = [ gitMinimal ];

  preCheck = ''
    export HOME="$TMPDIR"
    substituteInPlace internal/update/autoupdate_test.go \
      --replace-warn '#!/bin/bash' '#!${runtimeShell}'
  '';

  # SLACK_SKIP_UPDATE turns off the CLI's own update check, which otherwise
  # runs in the background of every command once a day and then offers to
  # download a new release over the top of the running binary. Neither makes
  # sense out of the Nix store: the binary is read-only, and the version moves
  # when the flake does. --set-default, so exporting SLACK_SKIP_UPDATE as an
  # empty string still turns the check back on, for example to see whether
  # this flake is behind.
  #
  # --inherit-argv0, because the CLI names itself after argv[0] in its help
  # text, its examples and `--version`. Without it they would all say
  # .slack-cli-wrapped.
  postInstall = ''
    wrapProgram "$out/bin/slack-cli" \
      --inherit-argv0 \
      --set-default SLACK_SKIP_UPDATE 1
  '';

  passthru.updateScript = ./scripts/update.sh;

  meta = {
    description = "Slack's developer CLI, built from source, installed as slack-cli";
    longDescription = ''
      The Slack CLI, for creating, running and deploying Slack apps and
      managing them from the command line: collaborators, triggers,
      environment variables, datastores and manifests.

      Built from the source of a pinned upstream release tag. The binary is
      installed as slack-cli rather than slack, so that it does not shadow
      the Slack desktop application's own slack command.
    '';
    homepage = "https://docs.slack.dev/tools/slack-cli";
    downloadPage = "https://github.com/slackapi/slack-cli/releases";
    changelog = "https://github.com/slackapi/slack-cli/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "slack-cli";
  };
})
