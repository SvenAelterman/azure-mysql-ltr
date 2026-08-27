#!/usr/bin/env bash
set -euo pipefail

: "${STORAGE_ACCOUNT_NAME:?STORAGE_ACCOUNT_NAME is required}"
: "${BLOB_CONTAINER_NAME:?BLOB_CONTAINER_NAME is required}"
: "${MANAGED_IDENTITY_CLIENT_ID:?MANAGED_IDENTITY_CLIENT_ID is required}"

dump_file=""
previous_arg_was_result_file=false
for arg in "$@"; do
  if [ "$previous_arg_was_result_file" = true ]; then
    dump_file="$arg"
    previous_arg_was_result_file=false
    continue
  fi

  case "$arg" in
    --result-file=*)
      dump_file="${arg#--result-file=}"
      ;;
    --result-file)
      previous_arg_was_result_file=true
      ;;
  esac
done

if [ -z "$dump_file" ]; then
  echo "The mysqldump command must include --result-file." >&2
  exit 1
fi

mysqldump "$@"

azcopy login --identity --identity-client-id "$MANAGED_IDENTITY_CLIENT_ID"
azcopy copy "$dump_file" "https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${BLOB_CONTAINER_NAME}/$(basename "$dump_file")" --overwrite=true
