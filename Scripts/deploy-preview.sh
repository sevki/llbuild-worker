#!/usr/bin/env bash
# Deploys the built Worker (build/worker) as a Worker Preview named after the pull
# request (or branch), so a change can be tried and timed before it reaches the
# live cache. See https://blog.cloudflare.com/worker-previews/ and the `previews`
# block in wrangler.jsonc.
#
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. The preview's CAS_TOKEN
# secret comes from the Preview base config in the Cloudflare dashboard, so none is
# uploaded here. Without the credentials (a pull request from a fork gets none) it
# does nothing. On success it appends
# PREVIEW_URL=<url> to $GITHUB_ENV when that is set, and prints it.
set -euo pipefail

wrangler="${WRANGLER:-wrangler@4.145.0}"
name="${PREVIEW_NAME:-${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD)}}"

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    echo "::notice::No Cloudflare credentials (a pull request from a fork?): not deploying a preview"
    exit 0
fi
[ -s build/worker/worker.mjs ] || { echo "::error::build/worker is missing: build the Worker first"; exit 1; }

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

npx --yes "$wrangler" preview \
    --name "$name" \
    --message "${PREVIEW_MESSAGE:-${GITHUB_SHA:-local} from ${GITHUB_REPOSITORY:-this repository}}" 2>&1 | tee "$out"

# The command's output is not a documented format, so take the first preview
# URL it printed rather than a particular JSON field. A preview is served from
# workers.dev or, when the zone has a wildcard custom domain for previews (this
# one has *.xcache.devtoo.ls), from a subdomain of it; PREVIEW_URL_PATTERN
# overrides the match.
pattern="${PREVIEW_URL_PATTERN:-workers\.dev|previews|[A-Za-z0-9-]+\.xcache\.devtoo\.ls}"
url="$(grep -o -E 'https://[A-Za-z0-9._/-]+' "$out" | grep -i -E "$pattern" | head -n 1 || true)"
if [ -z "$url" ]; then
    echo "::error::Deployed, but found no preview URL in wrangler's output"
    exit 1
fi
echo "Preview: $url"
[ -z "${GITHUB_ENV:-}" ] || echo "PREVIEW_URL=$url" >> "$GITHUB_ENV"
