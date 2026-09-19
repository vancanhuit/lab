# SeaweedFS web UIs

The private lab exposes three web UIs through Nginx on HTTPS port 443:

| URL | Loopback backend | Purpose |
| --- | --- | --- |
| https://seaweedfs-master.lab.canhdinh.com | `127.0.0.1:9333` | Cluster topology and storage status |
| https://seaweedfs-filer.lab.canhdinh.com | `127.0.0.1:8888` | File browsing, upload, download, and deletion |
| https://seaweedfs-volume.lab.canhdinh.com | `127.0.0.1:8080` | Volume server status |

Each hostname is a CNAME pointing to `s3.lab.canhdinh.com`. The existing lego
certificate includes all three names and the S3 API hostname. SeaweedFS listeners
remain on loopback. Nginx requires Basic Auth for every path of each UI host and
removes the Authorization header before forwarding requests to SeaweedFS.
HTTP port 80 only redirects these UI hostnames to their canonical HTTPS URLs
with status `308`, preserving the path and query string without asking for
credentials. Other HTTP hostnames are rejected. HTTPS responses, including
authentication challenges, send HSTS (`max-age=31536000`) so browsers use HTTPS
for subsequent visits. HSTS is scoped to each UI hostname, without subdomains
or preload. Local Nginx-to-SeaweedFS connections use loopback HTTP.
The Volume hostname's root serves SeaweedFS's `/ui/index.html` page. Nginx rewrites
loopback HTTP links in Master HTML responses to the corresponding HTTPS UI hostnames,
so Master-to-Volume navigation works without changing cluster discovery addresses.

The shared `admin` account grants full access to these interfaces and their HTTP
APIs. The S3 API at `https://s3.lab.canhdinh.com` continues to use S3 credentials.

## Credentials

The username, random password, and salted bcrypt hash are encrypted with the
repository's age recipient in `ansible/host_vars/s3/secrets.sops.yaml`:

- `seaweedfs_ui_username`: `admin`
- `seaweedfs_ui_password`: recoverable login password
- `seaweedfs_ui_password_hash`: bcrypt hash with cost 12

Credentials were generated once; deployment never generates or rotates them.
Only the username and hash are copied to `/etc/nginx/seaweedfs.htpasswd`, owned by
`root:www-data` with mode `0640`. Secret-bearing Ansible tasks suppress logging.

To retrieve the password, open the encrypted file in a private local editor:

```sh
SOPS_FILE=host_vars/s3/secrets.sops.yaml mise run secrets:edit
```

Alternatively, on a Wayland desktop with `wl-copy`, copy only the password to the
clipboard without printing it (run from the repository root):

```sh
mise exec -- sops --decrypt --extract '["seaweedfs_ui_password"]' \
  ansible/host_vars/s3/secrets.sops.yaml | wl-copy
```

Clear the clipboard after use with `wl-copy --clear`. Avoid `secrets:view` in
recorded or shared terminals because it prints every secret in the file.

### Rotate the shared password

1. Generate a new password of at least 32 characters in a password manager.
2. On a trusted workstation with Apache `htpasswd` installed, generate its hash
   interactively with `htpasswd -nBC 12 admin`. Enter the new password at the
   prompts; do not pass it as a command-line argument.
3. Open the SOPS file using the edit command above. Update `seaweedfs_ui_password`
   and `seaweedfs_ui_password_hash` together, copying only the hash after `admin:`
   into the hash field. Keep `seaweedfs_ui_username` set to `admin`.
4. Deploy and verify using the commands below. Reauthenticate in the browser with
   the new password. All three UIs switch together.

## Deploy and verify

From `ansible/`:

```sh
mise exec -- ansible-playbook s3.yaml
mise exec -- ansible-playbook verify-s3.yaml
mise exec -- ansible-playbook s3.yaml
```

The final run should report `changed=0`. Verification checks services, loopback
backends, TLS validity and hostname coverage, password file permissions, rejected
unauthenticated and incorrect-password requests, and authenticated UI access.

An unauthenticated request should return `401` with a Basic Auth challenge:

```sh
curl -I https://seaweedfs-filer.lab.canhdinh.com/
```

For a login check that prompts for the password rather than putting it in shell
history, use `curl --user admin https://seaweedfs-filer.lab.canhdinh.com/`.
If login succeeds but Nginx returns `502`, check `seaweedfs.service` and its
loopback listeners. If certificate validation fails, check `lego-renew.service`
and the deployed certificate names before retrying.
