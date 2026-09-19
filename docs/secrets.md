# Secret management with SOPS and age

This repository uses [SOPS](https://getsops.io/) with [age](https://age-encryption.org/) to keep Ansible secrets encrypted in Git. SOPS encrypts the values in structured files while preserving enough YAML structure for useful reviews. age provides the asymmetric key pair that controls who can decrypt the file.

## Repository configuration

The secret-management configuration consists of:

- `mise.toml`, which pins the `sops` and `age` versions and defines the `secrets:edit`, `secrets:view`, and `secrets:check` tasks.
- [`ansible/.sops.yaml`](../ansible/.sops.yaml), which applies its age recipient to files ending in `.sops.yaml`.
- Encrypted SOPS variable files:
  - [`ansible/group_vars/lab/secrets.sops.yaml`](../ansible/group_vars/lab/secrets.sops.yaml), containing the secrets shared by all hosts in the `lab` group: `cloudflare_api_token`.
  - [`ansible/group_vars/gitea_stack/secrets.sops.yaml`](../ansible/group_vars/gitea_stack/secrets.sops.yaml), containing the secrets shared by hosts in the `gitea_stack` group (currently `postgres` and `gitea`): `gitea_database_password`.
  - [`ansible/group_vars/harbor_stack/secrets.sops.yaml`](../ansible/group_vars/harbor_stack/secrets.sops.yaml), containing the secrets shared by hosts in the `harbor_stack` group (`postgres` and `harbor`): `harbor_database_password`.
  - [`ansible/host_vars/dns/secrets.sops.yaml`](../ansible/host_vars/dns/secrets.sops.yaml), containing secrets owned by the `dns` host: `technitium_pfx_password`.
  - [`ansible/host_vars/gitea/secrets.sops.yaml`](../ansible/host_vars/gitea/secrets.sops.yaml), containing secrets owned by the `gitea` host: `gitea_s3_access_key`, `gitea_s3_secret_key`, `gitea_smtp_password`, `gitea_secret_key`, `gitea_internal_token`, `gitea_lfs_jwt_secret`, `gitea_admin_password`, `gitea_oauth2_jwt_secret`.
  - [`ansible/host_vars/harbor/secrets.sops.yaml`](../ansible/host_vars/harbor/secrets.sops.yaml), containing secrets owned by the `harbor` host: `harbor_admin_password`, `harbor_s3_access_key`, `harbor_s3_secret_key`.
  - [`ansible/host_vars/s3/secrets.sops.yaml`](../ansible/host_vars/s3/secrets.sops.yaml), containing secrets owned by the `s3` host: `seaweedfs_s3_access_key`, `seaweedfs_s3_secret_key`, `seaweedfs_gitea_access_key`, `seaweedfs_gitea_secret_key`, `seaweedfs_harbor_access_key`, `seaweedfs_harbor_secret_key`, `seaweedfs_ui_username`, `seaweedfs_ui_password`, `seaweedfs_ui_password_hash`. See [SeaweedFS UI credentials](seaweedfs.md#credentials) for retrieval and rotation.
- `ansible/ansible.cfg`, which enables the [`community.sops.sops` vars plugin](https://docs.ansible.com/projects/ansible/latest/collections/community/sops/sops_vars.html).
- `ansible/requirements.yaml`, which pins the `community.sops` Ansible collection.

The age recipient in `ansible/.sops.yaml` is a public key and is safe to commit. The corresponding age identity is the private key and must never be committed, pasted into tickets or chat, or stored in shell history.

## How encryption works

SOPS uses envelope encryption for each file:

1. SOPS generates a random data key for the file.
2. It encrypts the YAML values with that data key. YAML keys remain readable, which keeps diffs understandable without revealing their values.
3. SOPS encrypts a copy of the data key to every configured age recipient and stores those encrypted copies under the top-level `sops` metadata block.
4. SOPS stores a message authentication code in the metadata so unauthorized value additions, removals, or modifications are detected during decryption.
5. A matching age identity decrypts the file data key, after which SOPS can decrypt and authenticate the values.

The encrypted data key and metadata can be committed safely, but losing every matching age identity makes the secrets unrecoverable. Possession of a matching private identity grants access to every file encrypted for that recipient.

## Configure an operator identity

SOPS looks for age identities at `${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt` by default. Create a new identity only if one has not already been provisioned:

```sh
identity_dir="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age"
mkdir -p "$identity_dir"
chmod 700 "$identity_dir"
umask 077
age-keygen -o "$identity_dir/keys.txt"
```

> [!CAUTION]
> Do not overwrite an existing identity file. Before relying on it for production secrets, store the complete private identity in a protected [Bitwarden Secure Note](https://bitwarden.com/help/managing-items/#item-types) or an encrypted [Proton Pass](https://proton.me/pass) note. Losing the only copy makes the encrypted secrets unrecoverable and blocks deployments, maintenance, and disaster recovery.

[Proton Pass](https://proton.me/pass/security) uses zero-knowledge, end-to-end encryption, and its free plan includes unlimited notes and devices. It can hold the recovery copy when Bitwarden is not used.

Treat the password-manager copy as an operational continuity requirement:

- Protect the selected password-manager account with a strong, unique master password and multi-factor authentication, such as [Bitwarden two-step login](https://bitwarden.com/help/setup-two-step-login/).
- Restrict the vault item or organization collection to operators authorized to decrypt homelab secrets.
- Preserve the complete identity file content and label it with the matching public age recipient.
- After storing or updating the item, temporarily restore the identity on a trusted system, verify decryption to `/dev/null`, and securely remove the temporary copy.
- Review access and recovery procedures when operators or devices change.

The local identity file remains the working copy for SOPS. Bitwarden or Proton Pass holds the recovery copy so the loss of one workstation does not interrupt Ansible operations.

Print only the public recipient derived from the private identity:

```sh
age-keygen -y "${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
```

The resulting `age1...` recipient must match the recipient in `ansible/.sops.yaml`. For a non-default identity location, set `SOPS_AGE_KEY_FILE` for direct SOPS commands and `ANSIBLE_SOPS_AGE_KEYFILE` for the Ansible vars plugin:

```sh
export SOPS_AGE_KEY_FILE=/secure/path/keys.txt
export ANSIBLE_SOPS_AGE_KEYFILE=/secure/path/keys.txt
```

Environment variables containing private key material, such as `SOPS_AGE_KEY`, are supported but are less suitable for interactive use because environment contents can leak through process inspection, debugging output, or shell configuration.

## Edit and inspect secrets

Edit an encrypted file through SOPS rather than decrypting it to a persistent plaintext file. Specify the file relative to `ansible/` with the `SOPS_FILE` environment variable:

```sh
SOPS_FILE=host_vars/gitea/secrets.sops.yaml mise run secrets:edit
```

SOPS decrypts the values for the editor process, then validates and re-encrypts the file when the editor exits. Git continues to see only encrypted values.

Inspect decrypted values only when necessary:

```sh
SOPS_FILE=host_vars/gitea/secrets.sops.yaml mise run secrets:view
```

> [!WARNING]
> `secrets:view` prints every plaintext secret to the terminal. Do not run it in recorded terminals, CI logs, shared sessions, or commands whose output is redirected to an unencrypted file.

Test key access without displaying plaintext for a specific file:

```sh
sops --decrypt ansible/host_vars/gitea/secrets.sops.yaml >/dev/null
```

Or authenticate every encrypted inventory file at once:

```sh
mise run secrets:check
```

After editing, review the encrypted diff and ensure no plaintext file was created:

```sh
git diff --check
git diff -- ansible/host_vars/gitea/secrets.sops.yaml
git status --short
```

## Ansible decryption flow

The `community.sops.sops` vars plugin runs on the Ansible controller:

1. Ansible discovers encrypted `.sops.yaml` files while loading inventory variables.
2. The plugin invokes the local `sops` binary and obtains the age identity from the default key file or the configured environment override.
3. SOPS authenticates and decrypts each matching file in memory as Ansible loads it.
4. Ansible merges the resulting values according to normal group and host precedence, so secrets are available only to hosts that inherit or own them.
5. Only values required by a task are sent to managed hosts. The age private identity stays on the controller.

The vars plugin loads `.sops.yaml`, `.sops.yml`, and `.sops.json` files, while this repository's creation rule targets only `.sops.yaml` files. Run playbooks from `ansible/` so `ansible.cfg`, inventory, roles, and the vars plugin configuration are applied together.

## Add or rotate recipients

When onboarding another operator or rotating a key:

1. Generate or obtain the operator's public age recipient. Never exchange the private identity.
2. Add the recipient to the matching creation rule in `ansible/.sops.yaml`.
3. Update every encrypted inventory file's recipient metadata so its data key is wrapped for the new recipient:

   ```sh
   find ansible/group_vars ansible/host_vars -type f -name '*.sops.yaml' -print0 |
     while IFS= read -r -d '' secret_file; do
       sops updatekeys "$secret_file"
     done
   ```

4. Confirm the new identity can decrypt every file to `/dev/null` before removing the old recipient.
5. Revoke and securely delete the old private identity only after every encrypted file has been updated and recovery access has been tested.

Changing `ansible/.sops.yaml` alone affects new encryption operations; it does not automatically rewrite recipient metadata in files that are already encrypted. Keep at least one tested recovery identity until rotation is complete.
