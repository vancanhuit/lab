# Full administration for the subject-bound role, not the special root policy.
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}
