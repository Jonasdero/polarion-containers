#!/bin/bash

set -euo pipefail

POLARION_RW_DIRS=(
  "/opt/polarion/data/workspace"
  "/opt/polarion/polarion/extensions"
)

for dir in "${POLARION_RW_DIRS[@]}"; do
  mkdir -p "$dir"
  chown -R polarion:www-data "$dir"
  find "$dir" -type d -exec chmod 2775 {} +
done

mkdir -p /opt/polarion/data/workspace/.config
mkdir -p /opt/polarion/data/workspace/.metadata
chown -R polarion:www-data /opt/polarion/data/workspace
find /opt/polarion/data/workspace -type d -exec chmod 2775 {} +

echo "Normalized mounted volume permissions for workspace and extensions."
