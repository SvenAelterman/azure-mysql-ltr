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
    # If the parameter is specified as --result-file=filename.sql,
    # otherwise it might be specified without = between the param name and value
    # and then the next argument is the file name
    --result-file=*)
      dump_file="${arg#--result-file=}"
      ;;
    --result-file)
      previous_arg_was_result_file=true
      ;;
  esac

  # If this is the SQL password argument, replace the placeholder with the actual password
  if [[ "$arg" == '--password=${{MYSQL_PASSWORD}}' ]]; then
    set -- "${@/$arg/--password=$MYSQL_PASSWORD}"
  fi
done

if [ -z "$dump_file" ]; then
  echo "The mysqldump command must include --result-file." >&2
  exit 1
fi

echo "Running mysqldump..."
mysqldump "$@"

echo "Signing in to azcopy with managed identity..."
azcopy login --identity --identity-client-id "$MANAGED_IDENTITY_CLIENT_ID"

echo "Uploading $dump_file to Azure Blob Storage..."
destination="https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/${BLOB_CONTAINER_NAME}/$(basename "$dump_file")"
max_attempts=3
attempt=1

while ! azcopy copy "$dump_file" "$destination" --overwrite=true; do
  
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "azcopy copy failed after $max_attempts attempts." >&2
    exit 1
  fi

  # Add a 10 second sleep delay per retry
  sleep $((attempt * 10))

  attempt=$((attempt + 1))
  echo "azcopy copy failed. Retrying (attempt $attempt of $max_attempts)..." >&2

done

# TODO: After successful file copy with azcopy, delete local file
