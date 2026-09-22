#!/usr/bin/env bash
# Everything CI would run. No arguments, no state, no hardware needed.
set -euo pipefail
cd "$(dirname "$0")"

cleanup() { rm -f "${tmp_manifest:-}" "${tmp_code:-}"; }
trap cleanup EXIT

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
# service.luau is excluded deliberately: update(), onIpc() and onConfigChanged()
# are called by the Noctalia host, so luau-analyze reports them as unused
# functions. The pure modules have no such excuse.
luau-analyze als-brightness/policy.luau als-brightness/colortemp.luau \
  als-brightness/curve.luau als-brightness/profile.luau

echo
echo "--- manifest ---"
# parseFieldType() in the host returns ManifestFieldType::String for any type it
# does not recognise, so a typo in plugin.toml does not error anywhere -- it
# quietly turns the control into a text box. `noctalia plugins lint` is the only
# guard against that, so it runs here rather than being remembered.
if command -v noctalia >/dev/null 2>&1; then
  noctalia plugins lint . | sed 's/^/      /'
else
  echo "      skip: noctalia not on PATH"
fi

echo
echo "--- curve defaults agree ---"
# The manifest default (what the settings page shows) and the code default (what
# the service falls back to) must be the same list. Nothing else checks this, and a
# silent divergence would mean the number you can see is not the number in use.
tmp_manifest="$(mktemp)"
tmp_code="$(mktemp)"
python3 - als-brightness/plugin.toml >"$tmp_manifest" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    manifest = tomllib.load(fh)
for setting in manifest["setting"]:
    if setting.get("type") == "string_list":
        for node in setting["default"]:
            print(f"{setting['key']}\t{node}")
PY
luau tests/print-defaults.luau >"$tmp_code"
if diff -u "$tmp_manifest" "$tmp_code" >/dev/null; then
  echo "ok    plugin.toml and curve.luau ship the same $(wc -l <"$tmp_manifest" | tr -d ' ') nodes"
else
  echo "FAIL  the manifest and code curve defaults have drifted:"
  diff -u "$tmp_manifest" "$tmp_code" | sed 's/^/      /' || true
  exit 1
fi

echo
echo "--- tests ---"
luau tests/policy.test.luau
luau tests/colortemp.test.luau
luau tests/curve.test.luau
luau tests/profile.test.luau
