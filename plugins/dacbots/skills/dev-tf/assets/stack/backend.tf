# Configured entirely by -backend-config=<file> (see variables/*.backend.hcl
# and BACKEND / BACKEND_MAP in Taskfile.yml). This block stays bare: a
# literal bucket/prefix here would hold only until the first -reconfigure
# and then silently disagree with whatever -backend-config supplies. A
# single-environment stack may instead fill it in and skip the .backend.hcl
# -- tf-stack resolves BACKEND to this file. See docs/tf-stack.md.
terraform {
  backend "gcs" {}
}
