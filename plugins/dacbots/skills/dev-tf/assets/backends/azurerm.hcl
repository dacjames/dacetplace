# Selected by BACKEND=<id> (see BACKEND_MAP in the Taskfile). Copy this into
# <stack>/variables/<id>.backend.hcl and fill in the storage account,
# container and key. tf:setup is not implemented for this flavor --
# provision the storage account and container out of band (see
# references/backends.md for paste-in commands).
storage_account_name = ""
container_name       = ""
key                   = ""
