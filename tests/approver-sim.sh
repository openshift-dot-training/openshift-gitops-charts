#!/usr/bin/env bash
# tests/approver-sim.sh - run the approver Job's real script (rendered from the
# chart) against a fake `oc`, for every decision it can take.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

helm template test charts/olm-operator -n ns -f tests/olm-operator/manual-exact-version.yaml |
  yq 'select(.kind == "Job").spec.template.spec.containers[0].args[0]' > "$work/approve.sh"

# fake oc: state in $SIM (installed, phase, plans: "<name> <approved> <csv>...")
mkdir -p "$work/bin"
cat > "$work/bin/oc" <<'OC'
#!/bin/sh
case "$*" in
  *subscriptions*) cat "$SIM/installed" 2>/dev/null ;;
  *clusterserviceversions*) cat "$SIM/phase" 2>/dev/null ;;
  "get installplans"*) cat "$SIM/plans" ;;
  "patch installplans"*) ip=$3
     sed -i "s/^$ip false/$ip true/" "$SIM/plans"
     grep "^$ip " "$SIM/plans" | awk '{print $3}' > "$SIM/installed"; echo Succeeded > "$SIM/phase" ;;
esac
OC
chmod +x "$work/bin/oc"

fail=0
# case <name> <want> <dependencies> <plans> <installed> <expected exit> <expected log pattern>
case_() {
  local sim="$work/$1"; mkdir -p "$sim"; printf '%b' "$4" > "$sim/plans"
  [[ -n $5 ]] && { echo "$5" > "$sim/installed"; echo Succeeded > "$sim/phase"; }
  set +e
  out=$(SIM="$sim" PATH="$work/bin:$PATH" NS=ns SUBSCRIPTION=sub WANT="$2" DEPENDENCIES="$3" \
        TIMEOUT=2 POLL=1 sh "$work/approve.sh" 2>&1); rc=$?
  set -e
  if [[ $rc -eq $6 ]] && grep -q "$7" <<<"$out"; then echo "ok   $1"
  else echo "FAIL $1 (exit $rc, wanted $6 and /$7/)"; echo "$out" | sed 's/^/     /'; fail=1; fi
}
case_ install           op.v1.0.1 ""            "p1 false op.v1.0.1\n"            ""        0 "APPROVE p1"
case_ steady-state      op.v1.0.1 ""            "p1 true op.v1.0.1\n"             op.v1.0.1 0 "OK: op.v1.0.1 installed"
case_ newer-than-git    op.v1.0.1 ""            "p2 false op.v1.0.2\n"            op.v1.0.0 1 "SKIP p2"
case_ mixed-plan        op.v1.0.1 ""            "p3 false op.v1.0.1 other.v2.0.0\n" ""      1 "REFUSE p3"
case_ exact-deps        op.v1.0.1 "dep.v3.1.0"  "p4 false op.v1.0.1 dep.v3.1.0\n" ""        0 "APPROVE p4"
case_ exact-deps-other  op.v1.0.1 "dep.v3.0.0"  "p5 false op.v1.0.1 dep.v3.1.0\n" ""        1 "REFUSE p5"
case_ prefix-deps       op.v1.0.1 "dep"         "p6 false op.v1.0.1 dep.v3.1.0\n" ""        0 "APPROVE p6"
exit $fail
