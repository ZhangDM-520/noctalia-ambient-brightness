#!/usr/bin/env bash
# Everything CI would run. No arguments, no state, no hardware needed.
set -euo pipefail
cd "$(dirname "$0")"

cleanup() { rm -f "${tmp_expected:-}" "${tmp_actual:-}"; }
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
  als-brightness/curve.luau als-brightness/curve_source.luau \
  als-brightness/settings_spec.luau als-brightness/profile.luau \
  als-brightness/hardware.luau als-brightness/adaptation.luau \
  als-brightness/temperature.luau

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
echo "--- settings surface agrees ---"
# The manifest literals (what the settings page shows), the en.json row text
# (what the row promises the node outputs) and the code constants (what the
# service runs on) are three copies of the same facts. A silent divergence means
# the number you can see is not the number in use, or that a row promises an
# output its node no longer produces -- and until this check, prose values
# ("-> 5940K") were never checked at all: only the 40 numeric rows were.
#
# One authority per value, everything else checked against it:
#   node positions / outputs / slider windows  curve.luau (via settings_spec)
#   percent clamp defaults                     policy.luau (via settings_spec)
#   row text templates + number spelling       settings_spec.luau
# settings_spec.luau emits the expected rows; python3 flattens plugin.toml and
# translations/en.json into the same shapes and the streams are diffed line for
# line. Keys are compared too, not just values: the editor sorts rows by key as
# text, so a key that stops being zero-padded reorders the curve on screen
# without changing a single number.
tmp_expected="$(mktemp)"
tmp_actual="$(mktemp)"
luau tests/print-defaults.luau >"$tmp_expected"
python3 - als-brightness/plugin.toml als-brightness/translations/en.json \
  als-brightness/service.luau als-brightness/curve_source.luau "$tmp_actual" <<'PY'
import json, re, sys, tomllib

manifest_path, en_path, service_path, curve_source_path, out_path = sys.argv[1:6]

with open(manifest_path, "rb") as fh:
    manifest = tomllib.load(fh)
with open(en_path, encoding="utf-8") as fh:
    en = json.load(fh)["settings"]
with open(service_path, encoding="utf-8") as fh:
    service = fh.read()
with open(curve_source_path, encoding="utf-8") as fh:
    curve_source = fh.read()

settings = manifest["setting"]
by_key = {s["key"]: s for s in settings}
node_key = re.compile(r"^thr_(?:brightness|temperature)_\d\d$")
problems = []


def num(value):
    return format(value, "g") if isinstance(value, float) else str(value)


# The actual side: the same four row shapes settings_spec.surface_rows() emits.
rows = []
for s in settings:
    key = s["key"]
    if s.get("type") == "string_map":
        for map_key, value in sorted(s["default"].items()):
            rows.append("map\t{}\t{}\t{}".format(key, map_key, value))
    elif s.get("type") == "int" and key.startswith("thr_"):
        rows.append("thr\t{}\t{}\t{}\t{}\t{}".format(
            key, num(s["default"]), num(s["min"]), num(s["max"]), num(s["step"])))
    elif key in ("min_percent", "max_percent"):
        rows.append("pct\t{}\t{}".format(key, s["default"]))
for key in sorted(en):
    if node_key.match(key):
        rows.append("text\t{}\t{}\t{}".format(key, en[key]["label"], en[key]["description"]))

# Wiring: every [[setting]] resolves through its label_key/description_key into
# translations/en.json and back, exact spelling, no orphans either way.
for s in settings:
    key = s["key"]
    if s.get("label_key") != "settings.{}.label".format(key):
        problems.append("FAIL  {} label_key is {!r}, expected settings.{}.label".format(
            key, s.get("label_key"), key))
    if s.get("description_key") != "settings.{}.description".format(key):
        problems.append("FAIL  {} description_key is {!r}, expected settings.{}.description".format(
            key, s.get("description_key"), key))
    if key not in en:
        problems.append("FAIL  {} has no translations/en.json entry".format(key))
for key in sorted(en):
    if key not in by_key:
        problems.append("FAIL  translations/en.json entry {} matches no [[setting]]".format(key))

# Prose values: static row text must carry no numeric literal at all. Host
# labels are static strings, so a number in prose is unchecked by definition;
# if a row needs one, it must derive from a constant through settings_spec
# (the node rows do) rather than being typed into en.json.
non_node = 0
for key in sorted(en):
    if node_key.match(key):
        continue
    non_node += 1
    for field in ("label", "description"):
        value = en[key][field]
        if re.search(r"\d", value):
            problems.append("FAIL  {}.{} carries a numeric literal in static prose: {!r}".format(
                key, field, value))

# Read-helper fallbacks also live as literal defaults in the code
# (setting_number("min_percent", 15), setting_bool("enabled", true),
# read_bool(settings.learning_profile, false)). A literal must equal the
# shipped default; absence is fine -- a fallback expressed through
# policy.DEFAULTS has one owner already. Covers number, bool and string
# defaults so flipping a plugin.toml `default` cannot silently drift.
def canon(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)

fallback_specs = (
    ("service.luau", service, r'setting_number\("KEY",\s*([0-9.]+)\)',
     ("min_percent", "max_percent")),
    ("service.luau", service, r'setting_bool\("KEY",\s*(true|false)\)',
     ("enabled", "colortemp")),
    ("service.luau", service, r'setting_string\("KEY",\s*"([^"]*)"\)',
     ("backlight", "connector")),
    ("curve_source.luau", curve_source, r'read_bool\(settings\.KEY,\s*(true|false)\)',
     ("learning_profile",)),
)
for where, text, pattern, keys in fallback_specs:
    for key in keys:
        m = re.search(pattern.replace("KEY", key), text)
        if m and m.group(1) != canon(by_key[key]["default"]):
            problems.append(
                "FAIL  {} falls back to {} for {} but plugin.toml defaults to {}".format(
                    where, m.group(1), key, canon(by_key[key]["default"])))

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("ok    {} settings x 2 keys wired to translations/en.json, no orphans".format(len(settings)))
print("ok    the {} non-node rows carry no numeric literal in static prose".format(non_node))
print("ok    literal fallbacks (number/bool/string) match the manifest defaults")

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("".join(line + "\n" for line in sorted(rows)))
PY
if diff -u "$tmp_expected" "$tmp_actual" >/dev/null; then
  echo "ok    plugin.toml, en.json and the code constants ship the same $(wc -l <"$tmp_expected" | tr -d ' ') rows"
else
  echo "FAIL  the shipped settings surface has drifted from the code constants:"
  diff -u "$tmp_expected" "$tmp_actual" | sed 's/^/      /' || true
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
if row["description"] != manifest["description"]:
    print("FAIL  catalog.toml and plugin.toml disagree on the description")
    sys.exit(1)
print("ok    catalog.toml and plugin.toml both say {} and carry the same description".format(
    manifest["version"]))
PY

echo
echo "--- tests ---"
luau tests/policy.test.luau
luau tests/colortemp.test.luau
luau tests/temperature.test.luau
luau tests/curve.test.luau
luau tests/curve_source.test.luau
luau tests/settings_spec.test.luau
luau tests/adaptation.test.luau
luau tests/profile.test.luau
luau tests/hardware.test.luau
