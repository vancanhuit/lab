# Gitea Backblaze Storage Migration Design

## Status

Completed on 2026-08-14. Gitea now uses Backblaze S3-compatible object storage.
The source IDrive e2 bucket remains intact for rollback retention.

## Goal

Migrate all Gitea objects from the current S3-compatible bucket to the
Backblaze S3-compatible bucket, then redeploy Gitea with the Backblaze settings
already encrypted in `ansible/group_vars/all/secrets.sops.yaml`.

## Migration Strategy

Use `rclone` from the operator workstation with two in-memory configurations:

- Source credentials come from the committed SOPS file at Git `HEAD`.
- Destination credentials come from the modified SOPS file in the working tree.
- Credentials must only enter child-process environment variables. Commands and
  logs must not print decrypted values.

Perform an online bulk copy first. Stop Gitea before the final copy so no object
can be created or changed during cutover. Use copy semantics rather than sync
semantics so migration cannot delete destination objects.

## Cutover Sequence

1. Install a user-local `rclone` binary and validate source and destination
   bucket access.
2. Record source object count and total size.
3. Copy source objects to Backblaze while Gitea remains online.
4. Stop Gitea and confirm the service is inactive.
5. Repeat the copy to capture objects changed during the initial pass.
6. Run an integrity check between source and destination. Do not cut over when
   object counts, sizes, or content checks differ.
7. Run `ansible/gitea.yaml` with the modified SOPS file to render the Backblaze
   settings and restart Gitea.
8. Run `ansible/verify-gitea.yaml` and test representative object-backed content
   such as avatars, attachments, LFS objects, or packages that exist in this
   installation.

## Failure Handling

If copying or verification fails before deployment, leave Gitea stopped only
for the final-pass window, restart it with the existing configuration, and fix
the transfer issue. If validation fails after cutover, restore the five old S3
settings from Git `HEAD`, redeploy, and verify against the source bucket.

The source bucket remains unchanged and available throughout migration. Do not
delete it until Backblaze-backed Gitea has passed operational checks and a
separate retention period.

## Security Constraints

- Never print decrypted SOPS values or place credentials in shell history.
- Never store plaintext rclone configuration in the repository or persistent
  home-directory configuration.
- Use TLS for both S3 endpoints.
- Keep both application keys scoped to only their migration buckets.
- Remove transient files and environment state when migration exits.

## Acceptance Criteria

- Source and destination object inventories agree after Gitea is stopped.
- Integrity checking reports no differences or errors.
- Gitea runs with the Backblaze endpoint, region, bucket, and credentials.
- The deployment verification playbook passes without failures.
- Existing object-backed content remains downloadable.
- The old bucket remains intact for rollback.

## Verified Outcome

- Migrated 2 objects totaling 4,887 bytes.
- Final source and destination inventories matched.
- `rclone check --download --one-way` reported 2 matching files and no
   differences.
- `ansible-playbook gitea.yaml` completed with no failed or unreachable hosts.
- `ansible-playbook verify-gitea.yaml` passed all 17 tasks.
- Both migrated avatar objects returned HTTP 200 through Gitea with their exact
   source sizes and `image/png` content types.
- Transient migration files were removed after verification.

## Documentation Maintenance

The README describes Backblaze as the current Gitea object-storage provider and
links to this migration record. Earlier Gitea deployment design and plan files
retain their original IDrive e2 text as historical context, with a notice that
this migration supersedes their object-storage sections.
