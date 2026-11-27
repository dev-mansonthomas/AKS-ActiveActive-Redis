# Fixture: the shipped example is a complete, valid GCP config once its <yourname> placeholder is filled.
# shellcheck source=/dev/null
. <(sed "s/<yourname>/test/" "$REPO_ROOT/config.example.sh")
CLOUD_PROVIDER=gcp
