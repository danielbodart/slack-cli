# slack-cli

A Nix flake for Slack's **official** developer CLI,
[slackapi/slack-cli](https://github.com/slackapi/slack-cli), built from source
at a pinned release and installed as **`slack-cli`**.

It is the CLI for creating, running and deploying Slack apps, and for managing
existing ones from a terminal: collaborators, triggers, environment variables,
datastores, manifests. For example:

```bash
slack-cli collaborator add someone@example.com --team T0123456789 --app A0123456789
```

```nix
{
  inputs.slack-cli.url = "github:danielbodart/slack-cli";
}
```

## Why `slack-cli` and not `slack`

Upstream installs its binary as `slack`. So does the Slack desktop app, whose
`slack` launches the chat client and is on the `PATH` of anyone who has it
installed. Two packages providing `bin/slack` in one profile collide, and
whichever wins, one of them stops working under its usual name.

So this package installs the CLI as `slack-cli`, and nothing else. That is not
a rename bolted on afterwards: `main.go` is at the root of the Go module
`github.com/slackapi/slack-cli`, so `slack-cli` is the name Go gives the binary
before upstream's Makefile and goreleaser rename it. And the CLI names itself
after `argv[0]` in its help, examples and `--version`, so it says `slack-cli`
throughout:

```console
$ slack-cli --version
Using slack-cli v4.13.0
```

Slack's documentation says `slack`; read it as `slack-cli`. If you want the
upstream name and do not have the desktop app, an alias does it:

```nix
home.shellAliases.slack = "slack-cli";
```

## What this one does

- **Builds from source.** The CLI is Apache-2.0, so there is no vendor binary
  to trust: `buildGoModule` compiles the commit Slack's release tag points at,
  with `CGO_ENABLED=0` like Slack's own Linux builds, and runs upstream's unit
  tests against it.
- **Reports its real version.** The version is linked in with the same
  `-X .../internal/version.Version` upstream's Makefile sets from
  `git describe`, so `slack-cli --version` says the release, not
  `v0.0.0-dev`.
- **Does not try to update itself.** See [Self-update](#self-update).
- **Updates itself hourly**, and only lands a version that has been built,
  tested and run on both x86\_64 and aarch64 first.
- **Tags every release**, so `github:danielbodart/slack-cli/v4.13.0` pins one
  exactly, with the same version number as upstream.

## Install

### NixOS or Home Manager

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    slack-cli.url = "github:danielbodart/slack-cli";
  };

  outputs = { nixpkgs, slack-cli, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        {
          environment.systemPackages = [
            slack-cli.packages.x86_64-linux.default
          ];
        }
      ];
    };
  };
}
```

or, in Home Manager:

```nix
home.packages = [ inputs.slack-cli.packages.${pkgs.system}.default ];
```

There is no NixOS or Home Manager module: the CLI is one binary with nothing
to configure system-wide, so a module would only be a longer way of adding a
package.

### Overlay

`overlays.default` adds `pkgs.slack-cli`, built by your nixpkgs instead of
this flake's. That is a build from source on your machine, since Cachix holds
only this flake's build, and it needs your nixpkgs to have the `go_1_NN` that
upstream's `go.mod` asks for.

### Try it without installing

```bash
nix run github:danielbodart/slack-cli -- --version
```

## Self-update

Left to itself, the CLI checks GitHub for a newer release once a day in the
background of whatever command you run, and then offers to download it and
replace its own binary. Out of the Nix store neither makes sense: the binary
is read-only, and the version moves when this flake does.

Upstream has a switch for that, the `SLACK_SKIP_UPDATE` environment variable,
which the package's wrapper sets to `1` when it is not already set. Export it
as an empty string to turn the daily check back on.

The same switch also silences the daily notice about updates to a project's
Slack SDK, which upstream checks in the same pass. `slack-cli upgrade` still
checks for both whenever you run it, which is the way to see whether this
flake has fallen behind Slack; it just cannot install the CLI half, because
the store is read-only.

Nothing else about the CLI is changed. In particular its telemetry is left as
upstream ships it; set `SLACK_DISABLE_TELEMETRY=true` yourself if you want it
off.

## Channels

- **Nix**: take the flake as an input and install `packages.<system>.default`,
  or use `overlays.default`. Built by nixpkgs (nixos-26.05) from Slack's source
  at the release tag, for x86\_64 and aarch64 Linux; CI pushes the packages to
  `https://danielbodart.cachix.org` (see [Binary cache](#binary-cache)). No
  `inputs.nixpkgs.follows`, for a different reason from the other
  danielbodart repackagings (see below).
- Not shipped: Docker. A developer CLI that keeps its login in your home
  directory; a container would only add a volume to get it back.
- Not shipped: Tarball + systemd. Slack already publishes tarballs of this
  exact CLI on its releases page, and it is not a service.

Updated hourly for a new upstream release (`upstream.yml`, which tags and
releases it) and weekly, Sunday 21:23 UTC, for the flake's inputs
(`update.yml`, the Weekly update). A release is cut only when Slack's version
changed; the weekly update never releases.

### Why not `inputs.nixpkgs.follows`

The Electron repackagings say not to follow your nixpkgs because they are
patched against this flake's glibc, GTK and NSS, and following yours would
rebuild them and keep a second set of those libraries. A static Go binary
links none of that, so that argument does not apply here: the closure is the
binary, its small wrapper, and the glibc that wrapper links, which your system
already has.

It is still better not to follow, for two smaller reasons:

- **It only costs you the cache.** nixpkgs contributes nothing to what the CLI
  does at runtime except the Go compiler's standard library. Following yours
  changes the store path, so Cachix has nothing for you and you compile it
  yourself, for no difference you could observe.
- **It can stop it building.** Upstream moves to new Go releases quickly; v4.13.0
  needs Go 1.27.3. This flake's lock is moved weekly and its Go is the one CI
  built and tested with. Yours might not have that `go_1_NN` at all.

The weekly update keeps this flake's Go current, which is where its security
fixes come from.

## How updates work

An hourly job asks GitHub for slackapi/slack-cli's latest release (not drafts,
not pre-releases). When it is newer than the pin, `scripts/update.sh` resolves
the tag to its commit, hashes the source at that commit, reads the Go version
out of its `go.mod`, and has Nix vendor its Go modules to learn `vendorHash`.
The package is then built, tested and run on both `x86_64-linux` and
`aarch64-linux` runners. Only if both succeed does the commit reach `trunk`,
followed by a `v<version>` tag and a GitHub release.

`sources.json` pins the commit, not the tag, so a tag Slack later moves or
deletes cannot change what an existing pin builds. CI re-derives the file on
every push and fails if it disagrees with upstream at the same version.

This pushes to `trunk` rather than opening a pull request on purpose. A pull
request raised with the default token does not trigger workflows, so an
auto-merged one would land without ever having been built.

Once a week, Sunday 21:23 UTC, a separate workflow, the Weekly update, moves
`flake.lock` (nixpkgs, on nixos-26.05), built and run the same way before it
lands as `Weekly update: <inputs>`. That is not a release, so it gets no tag.

Nothing about this changes when you pin a tag. `nix flake update` is still the
only thing that moves your version.

## Development

```bash
nix develop              # curl, jq, shellcheck, nixfmt
nix flake check          # builds and tests the CLI, checks version and closure
./scripts/update.sh      # regenerate sources.json
./scripts/update.sh --check   # exit non-zero if a newer version exists
./scripts/update.sh --force   # rewrite even when already current
```

## Binary cache

CI pushes both architectures to `https://danielbodart.cachix.org`, so you can
substitute the build instead of compiling it yourself.

The flake offers the cache through `nixConfig`, which Nix applies only if you
are a trusted user and otherwise reports as ignored. On NixOS the reliable
place to put it is your own configuration:

```nix
nix.settings = {
  substituters = [ "https://danielbodart.cachix.org" ];
  trusted-public-keys = [
    "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
  ];
};
```

## License

The packaging in this repository is MIT. The Slack CLI itself is
[Apache-2.0](https://github.com/slackapi/slack-cli/blob/main/LICENSE),
copyright Salesforce, Inc. This repository contains none of Slack's source;
it records which commit to fetch and what it should hash to. The builds in
the Cachix cache are of that source, unmodified, under its Apache-2.0
license.
