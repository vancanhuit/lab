# Gitea operations

## First login

Open `https://gitea.lab.canhdinh.com/` and sign in as `gitea-admin`. The initial password is stored in the SOPS key `gitea_admin_password`; Gitea requires an immediate password change on first login.

User registration is enabled, and new accounts must confirm their email address through the configured Brevo transactional mail service.

## Health checks

Run these commands on the Gitea host:

```sh
sudo systemctl status gitea.service
sudo journalctl -u gitea.service --since today
sudo -u git /usr/local/bin/gitea doctor check --default --config /etc/gitea/app.ini
sudo systemctl status lego-renew.timer
```

## Object storage

Gitea uses the local SeaweedFS S3-compatible API as its object-storage backend. It stores LFS objects, user and repository avatars, attachments, repository archives, packages, Actions logs, and Actions artifacts in the `homelab-gitea` bucket. Git repository object data remains under `/var/lib/gitea` on the Gitea host.

SeaweedFS grants Gitea a bucket-scoped identity with read, list, tagging, and write access only to `homelab-gitea`. The SeaweedFS administrative identity is separate and is not deployed to the Gitea host. Both hosts need their own encrypted copy of the shared Gitea identity: Gitea uses it as an S3 client, while SeaweedFS uses it to define the server-side authorization policy.

Run `ansible-playbook verify-gitea.yaml` after storage configuration changes. Do not inspect `/etc/gitea/app.ini` in shared or recorded terminals because it contains object-storage credentials.

The migration from Backblaze to SeaweedFS was manually verified on 2026-09-12. A comparison performed while writes were frozen found two matching objects totaling 4,887 bytes and no content differences. Confirm the former Backblaze bucket still exists and remains suitable before treating it as a rollback source.

Changing storage providers requires data migration as well as configuration deployment:

1. Copy the existing bucket to the destination while Gitea remains online.
2. Stop Gitea to freeze object writes.
3. Copy the final delta and compare object counts, byte totals, and contents.
4. Update the `gitea_s3_*` inventory values and run `ansible-playbook gitea.yaml`.
5. Run `ansible-playbook verify-gitea.yaml` and test existing object-backed content through Gitea.
6. Retain the source bucket for a rollback period.

To roll back during that period, stop Gitea and sync the final SeaweedFS delta back to Backblaze. Verify the object count, byte total, and contents before changing the inventory. Restore `gitea_s3_endpoint` to `s3.us-west-004.backblazeb2.com`, `gitea_s3_region` to `us-west-004`, and `gitea_s3_bucket_lookup_type` to `auto`. Then run `ansible-playbook gitea.yaml --limit gitea` and `ansible-playbook verify-gitea.yaml`. Do not switch the endpoint before the reverse sync passes.

## Upgrade procedure

Stop Gitea and take a consistent backup before changing `gitea_version`:

```sh
sudo systemctl stop gitea.service
```

Do not upgrade until you accept the repository and generated-state backup limitation described under [Backup coverage](backups-and-postgresql.md#backup-coverage). A Gitea upgrade also requires updating the supported-version assertion in `roles/gitea/tasks/validate.yaml`, the expected version in `verify-gitea.yaml`, and the version expectations in `roles/gitea/tests/render-config.yml`. Then run the role test, deployment, and verification playbook.
