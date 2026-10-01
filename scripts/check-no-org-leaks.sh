#!/usr/bin/env bash
# Fails if employer-specific identifiers reappear in tracked files.
set -euo pipefail
pattern='Ala-com|ala\.com|JWT-[0-9]|7Y7HCMY4K5|com\.floc|Barto|Rippling|backend-(account|worker|rental|rag)|Hubert-ale|REPO_PASSWORD'
if git grep -n -I -i -E "$pattern" -- . ':!scripts/check-no-org-leaks.sh'; then
  echo "Org-specific identifiers found (see above)." >&2
  exit 1
fi
