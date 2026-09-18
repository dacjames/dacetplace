# Selected by BACKEND=<id> (see BACKEND_MAP in the Taskfile). Copy this into
# <stack>/variables/<id>.backend.hcl and fill in bucket/prefix -- tf_setup
# and -backend-config both read the per-id copy under variables/, never this
# template directly.
bucket = ""
prefix = ""
