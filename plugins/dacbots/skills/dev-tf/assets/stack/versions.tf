terraform {
  required_version = ">= 1.7.0"

  required_providers {
    # Add providers here as the stack needs them. Left empty in a fresh
    # scaffold so `task tf:init:local` and `task tf:validate:local` succeed
    # offline, with no credentials and no network.
  }
}
