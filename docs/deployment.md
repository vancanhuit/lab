# Deployment sequence

Run these stages in order. DNS must resolve the service hostnames before the other services request certificates. PostgreSQL and SeaweedFS must be available before Gitea or Harbor starts using those external data services.

Run all commands below from the `ansible/` directory:

```sh
cd ansible
```

## 1. Deploy DNS

Technitium DNS is installed manually on `dns.lab.canhdinh.com`. On the DNS host, run:

```sh
curl -sSL https://download.technitium.com/dns/install.sh | sudo bash
```

Configure the `lab.canhdinh.com` zone and its host records in Technitium, then obtain and deploy its TLS certificate with `lego`:

```sh
ansible-playbook dns.yaml
```

There is no dedicated DNS verification playbook. Before continuing, confirm that all deployment hostnames resolve from the Ansible controller:

```sh
getent hosts dns.lab.canhdinh.com
getent hosts postgres.lab.canhdinh.com
getent hosts gitea.lab.canhdinh.com
getent hosts kuma.lab.canhdinh.com
getent hosts s3.lab.canhdinh.com
getent hosts harbor.lab.canhdinh.com
```

## 2. Deploy PostgreSQL

Deploy PostgreSQL 18 and its `lego`-managed TLS certificate:

```sh
ansible-playbook postgres.yaml
```

Verify the PostgreSQL service, TLS endpoint, backup configuration, and timers:

```sh
ansible-playbook verify-postgres.yaml
```

Rerun the deployment to verify idempotence:

```sh
ansible-playbook postgres.yaml
```

The second deployment should report `changed=0` for the PostgreSQL host.

## 3. Deploy SeaweedFS S3

Create a private Technitium A record for `s3.lab.canhdinh.com` pointing to the container address, then deploy SeaweedFS. The verification playbook checks the HTTPS boundary and confirms that unauthenticated requests are rejected. It also validates the certificate, services, timers, and data mount:

```sh
ansible-playbook s3.yaml
ansible-playbook verify-s3.yaml
ansible-playbook s3.yaml
```

The second deployment should report `changed=0` for `s3`. SeaweedFS data and metadata are stored on the separate `pool1` custom volume mounted at `/var/lib/seaweedfs`; the container root disk does not hold object data. Nginx serves the application endpoints on HTTPS port 443; port 80 only redirects UI hostnames to HTTPS and rejects other hosts. SeaweedFS master, volume, filer, and S3 listeners bind to loopback.

The role creates the `homelab-gitea` and `homelab-harbor` buckets with their respective application owners before Gitea or Harbor is deployed. Existing buckets are left unchanged, including the Gitea bucket migrated from Backblaze.

The [Master, Filer, and Volume web UIs](seaweedfs.md) use separate HTTPS hostnames
with CNAME records pointing to `s3.lab.canhdinh.com`. Nginx requires the shared
`admin` Basic Auth account on all three UI hosts. The credentials are stored in
the S3 host's SOPS file; deployments reuse the stored bcrypt hash. The certificate
covers all four hostnames. `verify-s3.yaml` checks certificate validation,
unauthenticated and incorrect-password rejection, and authenticated UI access.

The role checks that `/var/lib/seaweedfs` is a mount point before making deployment
changes, including in check mode. The systemd service also requires its mounts and
asserts that the data directory is a mount point before starting. If either check
fails, restore the Incus data-volume attachment before retrying; creating an empty
directory on the root filesystem does not satisfy the guard.

## 4. Deploy Harbor

Harbor 2.15.2 runs on Docker Engine and Docker Compose installed using [Docker's official Debian repository](https://docs.docker.com/engine/install/debian/). The playbook creates the `harbor` PostgreSQL role and database, creates the `homelab-harbor` SeaweedFS bucket with a bucket-scoped identity, and deploys Harbor with trusted HTTPS and its bundled Trivy vulnerability scanner. Trivy updates its vulnerability databases from the upstream Aqua Security OCI repositories. Registry blobs use SeaweedFS; Harbor metadata uses PostgreSQL with `verify-full` TLS, validating the certificate chain and `postgres.lab.canhdinh.com` hostname. Valkey, Trivy databases, generated configuration, logs, and Docker images remain local to the Harbor VM.

```sh
ansible-playbook harbor.yaml
ansible-playbook verify-harbor.yaml
ansible-playbook harbor.yaml
```

The second deployment should report `changed=0` for `postgres`, `s3`, and `harbor`.

Verification confirms the Harbor version, service and certificate health, PostgreSQL TLS configuration, S3 driver selection, and Trivy registration. It does not push or pull an artifact, perform S3 object I/O, run a vulnerability scan, or validate a Trivy database update.

## 5. Deploy Gitea

Gitea depends on PostgreSQL and SeaweedFS from the previous stages. The Gitea playbook creates its PostgreSQL role and database before deploying Gitea with built-in HTTPS.

The role renders `gitea_s3_endpoint`, `gitea_s3_region`, `gitea_s3_bucket`, `gitea_s3_access_key`, and `gitea_s3_secret_key` into Gitea's `minio` storage backend. The active endpoint is `s3.lab.canhdinh.com`, using path-style lookup for `homelab-gitea`. Store the endpoint as a hostname without an `http://` or `https://` prefix. Changing these values switches configuration only; it does not migrate objects.

```sh
ansible-playbook gitea.yaml
```

Verify the Gitea service, listener, TLS endpoint, SeaweedFS endpoint configuration, administrator, and doctor checks:

```sh
ansible-playbook verify-gitea.yaml
```

Rerun the deployment to verify idempotence:

```sh
ansible-playbook gitea.yaml
```

The second deployment should report `changed=0` for both the Gitea and PostgreSQL hosts.

## 6. Deploy the Gitea Actions runner

Provision the dedicated VM and Docker block volume as described in [Gitea Actions runner](gitea-runner.md), then create a Technitium DHCP reservation and private A record for `gitea-runner.lab.canhdinh.com`.

Deploy and verify the runner:

```sh
ansible-playbook gitea-runner.yaml
ansible-playbook verify-gitea-runner.yaml
ansible-playbook gitea-runner.yaml
```

The deployment obtains the instance registration token from the Gitea CLI without storing it in inventory. The second deployment should report `changed=0` for both `gitea` and `gitea_runner`.

## 7. Deploy Uptime Kuma

Uptime Kuma stores its state in a local SQLite database and has no PostgreSQL runtime dependency. The Kuma playbook deploys the native application behind Nginx with a lego-managed TLS certificate.

```sh
ansible-playbook kuma.yaml
```

The first deployment installs the infrastructure but leaves Kuma waiting for one-time database setup through its web interface. Complete the [Uptime Kuma First Login and Setup](uptime-kuma.md#first-login-and-setup) before running verification.

Verify the Kuma service, listener, TLS endpoint, backup configuration, and timers:

```sh
ansible-playbook verify-kuma.yaml
```

Rerun the deployment to verify idempotence:

```sh
ansible-playbook kuma.yaml
```

The second deployment should report `changed=0` for `kuma`.
