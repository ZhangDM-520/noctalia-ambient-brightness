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
# the service falls back to) must be the same table. Nothing else checks this, and a
# silent divergence would mean the number you can see is not the number in use.
#
# The keys are compared too, not just the values: the editor sorts rows as text, so
# a key that stops being zero-padded reorders the curve on screen without changing
# a single number.
tmp_manifest="$(mktemp)"
tmp_code="$(mktemp)"
python3 - als-brightness/plugin.toml >"$tmp_manifest" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    manifest = tomllib.load(fh)
sliders = []
for setting in manifest["setting"]:
    if setting.get("type") == "string_map":
        for key, value in sorted(setting["default"].items()):
            print(f"{setting['key']}\t{key}\t{value}")
    elif setting.get("type") == "int" and setting["key"].startswith("thr_"):
        sliders.append(setting)
# The 20 threshold sliders drift-check the same way: manifest literals (default,
# min, max, step) against curve.DEFAULT_*_X and curve.threshold_window.
for setting in sorted(sliders, key=lambda s: s["key"]):
    print("{}\t{}\t{}\t{}\t{}".format(
        setting["key"], setting["default"], setting["min"], setting["max"], setting["step"]))
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
echo "--- catalog version agrees ---"
# `noctalia msg plugins list` shows the version from catalog.toml's row, not from
# plugin.toml. A version bump that touches only one of them mislabels the
# installed plugin (hit for real in Phase 6: the list kept saying 0.3.0 while the
# page ran the 0.4.0 code).
python3 - als-brightness/plugin.toml catalog.toml <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    manifest = tomllib.load(fh)
with open(sys.argv[2], "rb") as fh:
    catalog = tomllib.load(fh)
row = next(p for p in catalog["plugin"] if p["id"] == "zhangdm/als-brightness")
if row["version"] != manifest["version"]:
    print("FAIL  catalog.toml says {} but plugin.toml says {}".format(
        row["version"], manifest["version"]))
    sys.exit(1)
print("ok    catalog.toml and plugin.toml both say {}".format(manifest["version"]))
PY

echo
echo "--- tests ---"
luau tests/policy.test.luau
luau tests/colortemp.test.luau
luau tests/curve.test.luau
luau tests/profile.test.luau
