# Selected by BACKEND=<id> (see BACKEND_MAP in the Taskfile). Copy this into
# <stack>/variables/<id>.backend.hcl and fill in bucket/key/region.
# use_lockfile is tofu's native S3 locking; drop it and add dynamodb_table
# instead for terraform, which does not support use_lockfile. tf:setup is
# not implemented for this flavor -- provision the bucket out of band (see
# references/backends.md for paste-in commands).
bucket       = ""
key          = ""
region       = ""
use_lockfile = true
