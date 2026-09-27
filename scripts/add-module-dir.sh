#!/usr/bin/env bash
# Publish a module that lives in a sub-directory of an existing submodule
# (a monorepo such as logos-kit): lists it in modules.json and generates
# its per-module release workflow.
#
# Usage:
#   ./scripts/add-module-dir.sh submodules/logos-kit/modules/<module>

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

MODULE_PATH="${1:-}"
if [ -z "${MODULE_PATH}" ] || [ ! -f "${MODULE_PATH}/metadata.json" ]; then
  echo "usage: $0 <path-to-module-dir>   (the dir must hold metadata.json)" >&2
  exit 2
fi

NAME="$(jq -er .name "${MODULE_PATH}/metadata.json")"
TEMPLATE=".github/workflows/release-module.yml.template"
WORKFLOW=".github/workflows/release-${NAME}.yml"

sed -e "s|__MODULE_PATH__|${MODULE_PATH}|g" -e "s/__MODULE__/${NAME}/g" "${TEMPLATE}" > "${WORKFLOW}"
jq --arg p "${MODULE_PATH}" 'if (.modules | index($p)) then . else .modules += [$p] end' modules.json > modules.json.tmp
mv modules.json.tmp modules.json

echo "Added ${NAME} (${MODULE_PATH}). Commit modules.json and ${WORKFLOW}."
