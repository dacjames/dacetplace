# Configured entirely by -backend-config=<file> (see variables/*.backend.hcl
# and BACKEND / BACKEND_MAP in Taskfile.yml). This block must stay bare: a
# literal bucket/key/etc. here would hold only until the first -reconfigure
# and then silently disagree with whatever -backend-config supplies, and it
# would pin this stack to one backend flavor instead of letting BACKEND pick
# one per environment. See docs/tf-stack.md.
terraform {
  backend "__DEV_TF_BACKEND__" {}
}
