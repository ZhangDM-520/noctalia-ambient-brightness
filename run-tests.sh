#!/usr/bin/env bash
# Everything CI would run. No arguments, no state, no hardware needed.
set -euo pipefail
cd "$(dirname "$0")"

echo "--- syntax ---"
for f in als-brightness/*.luau; do
  if luau-compile "$f" >/dev/null; then
    echo "ok    $f"
  else
    echo "FAIL  $f"
    exit 1
  fi
done

echo
echo "--- lint ---"
# The three FunctionUnused findings on service.luau are expected: update(),
# onIpc() and onConfigChanged() are called by the Noctalia host, not by us.
luau-analyze als-brightness/policy.luau als-brightness/colortemp.luau

echo
echo "--- tests ---"
luau tests/policy.test.luau
luau tests/colortemp.test.luau
