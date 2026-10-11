#!/usr/bin/env bash
# scripts/validate.sh - checks for the generic charts (pre-commit hook and CI)
#
#   1. YAML files use .yaml (no .yml); YAML outside Helm templates parses
#   2. helm lint for every chart
#   3. tests/<chart>/*.yaml render; every "# expect: <yq expression>" line in a
#      fixture must evaluate to true on the array of rendered documents
#      (e.g. map(select(.kind == "Job")) | length == 1); fail-*.yaml fixtures
#      must NOT render
#   4. tests/approver-sim.sh: the approver Job's script against a fake oc
#
# Needs helm 3 and yq v4; missing tools are skipped with a warning unless
# REQUIRE_TOOLS=1 (CI).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
err() { echo "validate: $*" >&2; fail=1; }
need() {
  command -v "$1" >/dev/null && return 0
  if [[ ${REQUIRE_TOOLS:-0} == 1 ]]; then err "$1 not found"; else echo "validate: $1 not found - skipping" >&2; fi
  return 1
}
files=$(git ls-files --cached --others --exclude-standard)
yml=$(grep -E '\.yml$' <<<"$files" || true)
[[ -n $yml ]] && err "rename to .yaml: $(tr '\n' ' ' <<<"$yml")"
need yq && need helm || { (( fail == 0 )) && echo "validate: OK (partial)"; exit $fail; }

while IFS= read -r f; do
  [[ -f $f ]] && { yq eval-all 'true' "$f" >/dev/null 2>&1 || err "invalid YAML: $f"; }
done < <(grep -E '\.yaml$' <<<"$files" | grep -v '/templates/' || true)

out=$(mktemp); log=$(mktemp); trap 'rm -f "$out" "$out.all" "$log"' EXIT
for c in charts/*/; do helm lint --quiet "$c" >"$log" 2>&1 || err "helm lint $c: $(cat "$log")"; done

expect() { # <rendered file> <fixture>; expressions run on an array of all documents
  yq ea '[.]' "$1" > "$1.all"
  while IFS= read -r e; do
    [[ $(yq "$e" "$1.all" 2>&1) == true ]] || err "$2: expect failed: $e"
  done < <(sed -n 's/^# expect: //p' "$2")
}
for f in tests/olm-operator/*.yaml; do
  if helm template test charts/olm-operator -n ns -f "$f" >"$out" 2>/dev/null; then
    [[ $(basename "$f") == fail-* ]] && err "$f rendered but must fail" || expect "$out" "$f"
  else
    [[ $(basename "$f") == fail-* ]] || err "$f: $(helm template test charts/olm-operator -n ns -f "$f" 2>&1 | head -1)"
  fi
done
t=tests/platform-catalog
if helm template catalog charts/platform-catalog -f $t/catalog.yaml -f $t/groups.yaml >"$out" 2>"$log"; then
  expect "$out" $t/catalog.yaml
else err "platform-catalog: $(head -1 "$log")"; fi
helm template catalog charts/platform-catalog -f $t/catalog.yaml -f $t/fail-unknown-component.groups.yaml >/dev/null 2>&1 \
  && err "platform-catalog: unknown component in groups rendered but must fail"

tests/approver-sim.sh >"$out" 2>&1 || err "approver-sim: $(grep FAIL "$out")"
(( fail == 0 )) && echo "validate: OK"
exit $fail
