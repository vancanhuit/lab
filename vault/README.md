# Configure Vault SSO with Gitea

Vault uses the instance-wide confidential **Vault** OAuth application in Gitea
(application ID 10, client ID `9cb3a557-d895-4186-abff-f2d2d7a77422`). Manage it
under [Gitea Site Administration](https://gitea.lab.canhdinh.com/-/admin/applications),
not personal settings. Consent remains enabled.

The Vault API configuration is separate from the [Ansible server deployment](../docs/vault.md).
These files configure an initialized, unsealed Vault; routine Ansible deployment
does not load operator credentials or reconcile authentication.

## Access model

| Vault role | Gitea accounts | Vault permissions |
| --- | --- | --- |
| `admin` | Only `vancanhuit`, stable subject `2` | `gitea-admin`: full administration and secret access, including `sudo`, without the special `root` policy |
| `login` (default) | Any authenticated Gitea account | `gitea-login`: inspect, renew, or revoke its own token and inspect its own capabilities |

Both roles use the verified `email` claim as the Vault entity alias and require
`email_verified=true`. They request `openid email public-only`; Vault adds `openid`
automatically. Email is also copied to token and alias metadata. Tokens display
`oidc-<email>`; Vault adds the `oidc-` prefix. Log in again after identity changes
to refresh the token's display name and metadata.

Administrative access still requires `sub=2`, independently of the email address.
No username, email address alone, Gitea administrator flag, organization, or team
grants administration. Recreating the administrator's Gitea account changes its
subject and requires an explicit update to `oidc/admin.json`.

Email changes create another identity unless an operator updates the existing
alias first. Before an email change, verify ownership and check for alias conflicts,
then rename the alias through `identity/entity-alias/id/<alias-id>` while preserving
its canonical entity ID and mount accessor. Do not merge identities just because
their emails match. An address reassigned in Gitea can inherit the old Vault entity;
keep entity/group policies empty unless that lifecycle is managed explicitly.

The limited role does not inherit Vault's `default` policy, access shared
secrets or cubbyhole, create tokens, or manage policies, auth methods, or identities.
Email-confirmed Gitea registrations can sign in but receive no shared data access.
The UI may show an empty dashboard or permission-denied messages for unavailable
features. Selecting `admin` does not bypass its subject restriction.

Tokens start with a one-hour TTL and can renew up to a hard eight-hour limit.
Gitea logout or account removal does not revoke an already issued Vault token;
revoke it in Vault when immediate removal is needed. Keep Gitea administration
and account recovery secure: it is now a trust dependency for Vault administration.

## Sign in

Open [Vault's OIDC login](https://vault.lab.canhdinh.com/ui/vault/auth?with=oidc),
enter `admin` in **Role** for administrator access, and complete Gitea consent.
Leave the role blank, or enter `login`, for sign-in-only access.

For the CLI, run from the repository root on the workstation with your browser
and local port 8250 free:

```sh
mise exec -- vault login -method=oidc -no-print role=admin
mise exec -- vault token lookup -field=display_name
mise exec -- vault token capabilities sys/policies/acl/gitea-admin
```

Use `role=login` for the limited role. The CLI caches the resulting token in
`~/.vault-token`, replacing the previous cached login; keep this file mode `0600`.
Do not print unfiltered token lookup output. To display only the email metadata:

```sh
mise exec -- vault token lookup -format=json |
  mise exec -- python -c 'import json, sys; print(json.load(sys.stdin)["data"]["meta"]["email"])'
```

The browser and CLI use authorization-code flow with PKCE S256. Issuer, signature,
audience, state, nonce, and trusted TLS validation remain enabled. No direct JWT
login role or TLS bypass is configured. Gitea has no OIDC logout endpoint; sign out
of Gitea separately on a shared workstation.

## Apply or recover configuration

The confidential client configuration, including its secret, is encrypted in
[`secrets/vault/oidc.sops.json`](../secrets/vault/oidc.sops.json). Ansible never loads
it. Keep it separate from the root/unseal backup and do not put plaintext in
arguments, repository files, or recorded output.

These exact callback URIs must be registered in both Gitea and the two Vault roles:

- `https://vault.lab.canhdinh.com/ui/vault/auth/oidc/oidc/callback`
- `http://localhost:8250/oidc/callback`

With an authorized Vault administrator token, enable the auth mount once on a
fresh initialized server. Skip this command if `vault auth list` already shows
`oidc/`; never disable an existing mount just to reapply configuration.

```sh
mise exec -- vault auth enable -path=oidc -description="Gitea SSO" \
  -listing-visibility=unauth -default-lease-ttl=1h -max-lease-ttl=8h oidc
```

From the repository root, apply the policies, roles, and encrypted configuration.
This is safe to repeat and requires no service restart or unseal:

```bash
mise exec -- bash <<'SH'
set -euo pipefail
vault policy write gitea-login vault/oidc/login.hcl
vault policy write gitea-admin vault/oidc/admin.hcl
vault write auth/oidc/role/login @vault/oidc/login.json
vault write auth/oidc/role/admin @vault/oidc/admin.json
sops --decrypt secrets/vault/oidc.sops.json | vault write auth/oidc/config -
vault auth tune -listing-visibility=unauth -default-lease-ttl=1h -max-lease-ttl=8h oidc/
SH
```

To rotate the client secret, regenerate it on the existing Gitea application,
edit `secrets/vault/oidc.sops.json` with `mise exec -- sops`, then reapply the
encrypted configuration pipeline immediately. Do not recreate the application
during routine updates. Rebuilding Gitea without its database requires a new
registration and matching encrypted client ID/secret; do not reuse an old client
ID without its provider registration. Changed scopes require renewed consent.

If SSO fails, use the protected root recovery token with the token login method
in a private terminal. Fix or reapply the configuration without restarting Vault.
To remove SSO deliberately, `vault auth disable oidc/` revokes all tokens issued
through this mount and removes its roles/configuration. Remove the Gitea
application and unused policies only after accepting that rollback. It does not
delete secret-engine data or revoke the initial root token.

## Verification

Controller-local tests need no Vault credentials or cluster access. From `ansible/`:

```sh
mise exec -- ansible-playbook -i localhost, tests/vault-oidc.yml
mise exec -- ansible-lint tests/vault-oidc.yml
```

After applying or changing SSO:

1. Sign in through the browser and CLI as the account with subject `2`, selecting
   `admin`. Confirm the CLI display name is `oidc-vancanhuit@gmail.com`, the token
   includes `gitea-admin`, and the administration capability check succeeds.
2. In a separate session, sign in as a non-administrator account with `login`.
   For the `gitea-admin` Gitea account, expect display name
   `oidc-gitea-admin@canhdinh.com` and policy `gitea-login`. Shared secrets,
   cubbyhole, token creation, and administration must be denied.
3. Attempt to select `admin` with that limited account. Expect rejection by
   `bound_subject`. Vault 2.2.0 reports HTTP `500` with a subject-validation error
   for this case; do not treat that response as a successful login.
4. Revoke temporary test tokens and restore the administrator CLI login. Keep
   `~/.vault-token` at mode `0600`. Follow the [initialization runbook](../docs/vault.md#initialize-and-unseal-privately)
   to revoke the initial root token after non-root access and recovery are ready.

## References

- [Vault OIDC setup and redirect URIs](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Vault role constraints and claim mappings](https://developer.hashicorp.com/vault/api-docs/auth/jwt)
- [Gitea OAuth2 provider and restricted scopes](https://docs.gitea.com/development/oauth2-provider)
