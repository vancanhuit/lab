# Getting started

Run commands in this guide from the repository root unless a step changes directory.

## Prerequisites

- Install a minimal Debian 13 server with SSH access and sudo privileges.
- Install [Tailscale](https://tailscale.com/docs), join the tailnet, and configure split DNS for `lab.canhdinh.com`.
- Advertise the Incus bridge network from the Incus host through a [Tailscale subnet router](https://tailscale.com/kb/1019/subnets).
- Configure the Ansible inventory hosts in `ansible/inventory.yaml`.
- Add the required secrets to the encrypted files for their groups or hosts under `ansible/group_vars/` and `ansible/host_vars/`. [Repository configuration](secrets.md#repository-configuration) lists every encrypted file and its variables. Configure Uptime Kuma's native Brevo provider separately in its UI using values from your password manager.

## Enable Tailscale SSH

Enable [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh) on the Incus host so administrators can manage it remotely over the tailnet without distributing separate SSH user keys:

```sh
sudo tailscale set --ssh
```

> [!WARNING]
> Enabling Tailscale SSH can cause an existing SSH connection to the host's Tailscale IP to hang. Run the command from a local console or ensure another recovery path is available.

The tailnet policy must permit network access to the Incus host and Tailscale SSH access from authorized administrator identities to the existing local `lab` user. Tailscale SSH authenticates the tailnet identity; it does not create local operating-system accounts.

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

The roles and playbooks require Ansible Core 2.21 or newer; use the version pinned
in `mise.toml`. Text configuration reads use `slurp` with `armor: false` and
register projections, without separate decoding tasks. Roles and playbooks access
facts through `ansible_facts`; deprecated top-level fact injection is disabled in
`ansible.cfg`.
See the [2.21 release notes](https://github.com/ansible/ansible/blob/stable-2.21/changelogs/CHANGELOG-v2.21.rst)
and [2.20 fact-injection migration guidance](https://docs.ansible.com/projects/ansible/latest/porting_guides/porting_guide_core_2.20.html#inject-facts-as-vars).

Repository setup uses `deb822_repository` and installs its `python3-debian`
dependency either through the role's package prerequisites or the module's
`install_python_debian` option. Dependency installation requires a normal run;
PostgreSQL skips fresh-host configuration in check mode until those dependencies
and its runtime are present.

`mise run hooks:install` installs hooks that use Cocogitto to reject non-conventional commit messages and run Gitleaks and [TruffleHog](https://github.com/trufflesecurity/trufflehog) before every push. Run both secret scanners directly with `mise run security:secrets`.

Gitleaks scans the full Git history for secret patterns and redacts matches.
TruffleHog blocks credentials it verifies as active, along with candidates it
cannot verify because of a provider or network error. It may contact
credential-provider APIs during verification. The repository wrapper reports only
detector, status, file, line, and commit metadata; it does not print matched values.

List the available repository tasks:

```sh
mise task ls
```
