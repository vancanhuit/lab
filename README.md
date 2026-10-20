# Homelab with Incus, Cloudflare, and Tailscale VPN

This repository contains the Ansible configuration for a Debian 13 homelab running [Incus](https://linuxcontainers.org/incus/docs/main/), [Technitium DNS](https://technitium.com/dns/), [PostgreSQL](https://www.postgresql.org/docs/18/), [SeaweedFS](https://github.com/seaweedfs/seaweedfs), [Harbor](https://goharbor.io/docs/2.15.0/), [Gitea](https://docs.gitea.com/), [Gitea Actions](https://docs.gitea.com/runner/), [Uptime Kuma](https://github.com/louislam/uptime-kuma), and [HashiCorp Vault](https://developer.hashicorp.com/vault/docs) over a Tailscale virtual private network (VPN).

## Environment

| Component | Configuration |
| --- | --- |
| Hardware | Dell OptiPlex 7000 Micro, Intel Core i7-12700T (14 cores, 20 threads), 64 GB RAM, 2 TB NVMe SSD |
| Public domain | `canhdinh.com`, hosted by [Cloudflare DNS](https://developers.cloudflare.com/dns/) |
| Private domain | `lab.canhdinh.com`, resolved through [Tailscale split DNS](https://tailscale.com/kb/1054/dns#restricted-nameservers) |
| Host OS | Debian 13 |
| Virtualization | [Incus](https://linuxcontainers.org/incus/docs/main/) with ZFS storage |

The Incus host uses Zabbly builds for:

- [Incus](https://github.com/zabbly/incus)
- [ZFS](https://github.com/zabbly/zfs)
- [Linux kernel](https://github.com/zabbly/linux)

## Local tests

After installing the [local tooling](docs/getting-started.md), run:

```bash
mise run ansible:test
```

The task runs Ansible Core compatibility checks, every role's
`tests/render-config.yml`, standalone Kubernetes application checks, and the Kuma
backup behavior test against local fixtures. Application checks download and render
the pinned cert-manager and Argo CD Helm charts but do not contact a cluster.
An isolated localhost inventory lets you run it without an age identity or live
hosts. The tests cover template rendering, input validation, and shared production
checks. Command-validation fixtures check that a nonzero exit status fails
validation even when the output matches. Expected failures appear as rescued or
ignored tasks.

Run `verify-*.yaml` after deployment to check live service state; `verify-kuma.yaml`
also creates a backup and applies retention. The separate
`verify-inventory-vars.yaml` checks encrypted inventory ownership and requires the
configured age identity. See the [deployment guide](docs/deployment.md).

## Documentation

Start with [Getting started](docs/getting-started.md), then follow the deployment
runbook. Run commands from the repository root unless a page says otherwise.
Service runbooks cover setup, verification, upgrades, and recovery. Remove
upgrade-specific backups after all upgrade checks pass; see the
[backup cleanup policy](docs/backups-and-postgresql.md#backup-coverage).

| Guide | Contents |
| --- | --- |
| [Getting started](docs/getting-started.md) | Prerequisites, Tailscale SSH, and local tooling |
| [Secret management](docs/secrets.md) | SOPS, age identities, encrypted inventory variables, and key rotation |
| [Incus](docs/incus.md) | Host bootstrap, bridge networking, SSH keys, and instance creation |
| [TLS certificates](docs/tls.md) | Internal-service certificates, lego renewal, deployment hooks, and troubleshooting |
| [Deployment](docs/deployment.md) | Required deployment order and verification commands |
| [Uptime Kuma operations](docs/uptime-kuma.md) | Initial setup, monitoring, backup, restore, upgrade, and troubleshooting |
| [Vault operations](docs/vault.md) | Single-node systemd deployment, private initialization, unsealing, TLS, and snapshots |
| [Harbor operations](docs/harbor.md) | Registry use, vulnerability scanning, lifecycle, and upgrades |
| [Gitea operations](docs/gitea.md) | Initial access, object storage, migration rollback, and upgrades |
| [Gitea Actions runner](docs/gitea-runner.md) | Dedicated VM provisioning, deployment, workflows, and upgrades |
| [Kubernetes](docs/kubernetes.md) | Kubeadm, Cilium, Hubble UI, HAProxy Gateway API, and cert-manager DNS-01 |
| [Kubernetes applications](kubernetes/README.md) | Helm and kubectl deployment, Vault credentials, and Argo resource ownership |
| [Argo CD](kubernetes/argocd/README.md) | Pinned Helm deployment, shared HTTPS Gateway, DNS, and initial login |
| [Backups and PostgreSQL](docs/backups-and-postgresql.md) | Backup coverage, health checks, and point-in-time restore |
