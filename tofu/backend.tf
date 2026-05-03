terraform {
  backend "s3" {
    # Bucket / key / endpoint are injected by the Makefile through
    # `-backend-config=...` so they can come from the `.env` file.
    region = "us-east-1"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true

    use_path_style = true
    use_lockfile   = true
  }
}
