#!/usr/bin/env bash
# Rebuild web/vendor/anthropic-sdk.mjs: the Anthropic TypeScript SDK
# (@anthropic-ai/sdk, MIT), bundled into one browser module for the page's
# agent panel. The page is a static site with no build step of its own, and
# loading the SDK from a CDN would run a third party's script in the page
# that holds the owner's API key; so a pinned copy lives in the repository.
#   tools/vendor_sdk.sh [VERSION]
set -euo pipefail
version="${1:-0.131.0}"
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
npm init -y >/dev/null
npm install --silent --no-audit --no-fund "@anthropic-ai/sdk@$version" esbuild@0.25.0
echo 'export { default } from "@anthropic-ai/sdk";' > entry.mjs
npx esbuild entry.mjs --bundle --format=esm --platform=browser --minify --legal-comments=inline --outfile=bundle.mjs
{
  echo "// @anthropic-ai/sdk $version, bundled for the browser by tools/vendor_sdk.sh."
  echo "// Copyright 2023 Anthropic, PBC. MIT License (below). Do not edit: regenerate."
  sed 's#^#// #' node_modules/@anthropic-ai/sdk/LICENSE
  cat bundle.mjs
} > "$here/web/vendor/anthropic-sdk.mjs"
echo "web/vendor/anthropic-sdk.mjs: @anthropic-ai/sdk $version, $(wc -c < "$here/web/vendor/anthropic-sdk.mjs") bytes"
