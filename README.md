# Homelab Tailscale

```sh
mise task ls
```

```sh
mise run ansible:deps

cd ansible
ansible-playbook setup-incus.yaml --ask-become-pass
```
