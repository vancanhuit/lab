# Getting started

Run commands in this guide from the repository root unless a step changes directory.

## Prerequisites

- Install a minimal Debian 13 server with SSH access and sudo privileges.
- Install [Tailscale](https://tailscale.com/docs), join the tailnet, and configure split DNS for `lab.canhdinh.com`.
- Advertise the Incus bridge network from the Incus host through a [Tailscale subnet router](https://tailscale.com/kb/1019/subnets).
- Configure the Ansible inventory hosts in `ansible/inventory.yaml`.
- Add the required secrets to their ownership-scoped encrypted files under `ansible/group_vars/` and `ansible/host_vars/`. See the [Repository Configuration](secrets.md#repository-configuration) section for the complete list of encrypted files and their variables. Uptime Kuma's native Brevo provider is configured separately through its UI with password-manager values.

## Enable Tailscale SSH

Enable [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh) on the Incus host so administrators can manage it remotely over the tailnet without distributing separate SSH user keys:

```sh
sudo tailscale set --ssh
```

> [!WARNING]
> Enabling Tailscale SSH can cause an existing SSH connection to the host's Tailscale IP to hang. Run the command from a local console or ensure another recovery path is available.

Enabling Tailscale SSH on the host is only half of the setup. The tailnet policy must also permit network access to the Incus host and Tailscale SSH access from authorized administrator identities to the existing local `lab` user. Tailscale SSH authenticates the tailnet identity but does not create local operating-system accounts.

With MagicDNS enabled and the policy applied, connect from another tailnet device:

```sh
ssh lab@debian-incus
```

Use a narrowly scoped SSH policy and require check mode for interactive administrative access where practical. If Ansible connects through Tailscale SSH, ensure the selected policy supports non-interactive automation; check mode can require browser re-authentication and interrupt unattended runs.

## Install tooling

Install [`mise`](https://mise.jdx.dev/):

```sh
curl https://mise.run | sh
```

Install the pinned tools and Ansible collections:

```sh
mise install
mise run ansible:deps
mise run hooks:install
```

`mise run hooks:install` configures Cocogitto to reject non-conventional commit messages and runs Gitleaks and [TruffleHog](https://github.com/trufflesecurity/trufflehog) before every push. Run both secret scanners directly with `mise run security:secrets`.

Gitleaks performs a redacted full-history pattern scan. TruffleHog blocks credentials verified as active and candidates it cannot verify because of a provider or network error. TruffleHog may contact credential-provider APIs during verification; its repository wrapper reports only detector, status, file, line, and commit metadata so matched values are not printed.

List the available repository tasks:

```sh
mise task ls
```
