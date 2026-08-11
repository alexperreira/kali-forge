#!/usr/bin/env bash
#
# validate-package-list.sh
#
# Run this on the NEW Kali VM, against the package list captured from the old
# one. It answers the only question that actually matters when you bulk-transfer
# a years-old package list:
#
#     "Do all these names still exist?"
#
# Over several years of Kali releases, packages get renamed, merged into other
# packages, or dropped. `apt install` is all-or-nothing: ONE dead name in a list
# of 900 aborts the entire transaction with an unhelpful error. This script
# finds those names first, and suggests what they probably became.
#
# Usage:
#   ./validate-package-list.sh packages.txt [--apply]
#
#   (no flag)  report only, write the filtered lists, install nothing
#   --apply    additionally install everything in the OK list
#
# Outputs, next to the input file:
#   <name>.ok.txt        exists in apt, safe to install
#   <name>.present.txt   already installed on this VM, nothing to do
#   <name>.missing.txt   no longer exists — needs a human decision
#   <name>.report.txt    the missing ones with rename suggestions
#
set -euo pipefail

INPUT="${1:-}"
APPLY="${2:-}"

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  cat >&2 <<'EOF'
usage: ./validate-package-list.sh <packages.txt> [--apply]

  packages.txt   one package name per line (15-packages.txt from the capture)
  --apply        install the validated packages after reporting
EOF
  exit 1
fi

BASE="${INPUT%.*}"
OK="$BASE.ok.txt"
PRESENT="$BASE.present.txt"
MISSING="$BASE.missing.txt"
REPORT="$BASE.report.txt"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; }

command -v apt-cache >/dev/null || { err "apt-cache not found — is this Debian/Kali?"; exit 1; }

log "Refreshing apt cache"
if ! sudo apt-get update -qq; then
  warn "apt-get update reported errors (a third-party repo may be unreachable)."
  warn "Continuing with the cache as it stands — results may be slightly stale."
fi

# -----------------------------------------------------------------------------
# Build a set of every package name apt currently knows about, and every name
# already installed. Two big lookups beat 900 individual apt-cache calls —
# this turns a 4-minute run into about 4 seconds.
# -----------------------------------------------------------------------------
log "Indexing available packages"
AVAIL=$(mktemp); INSTALLED=$(mktemp); PROVIDES=$(mktemp)
trap 'rm -f "$AVAIL" "$INSTALLED" "$PROVIDES"' EXIT

apt-cache pkgnames | sort -u > "$AVAIL"
dpkg-query -W -f='${binary:Package}\n' 2>/dev/null \
  | sed -E 's/:[a-z0-9]+$//' | sort -u > "$INSTALLED"

# Virtual packages: a name can be gone as a real package but still resolvable
# because something else Provides: it. Those are fine to install.
apt-cache dumpavail 2>/dev/null \
  | awk -F': ' '/^Provides:/ {gsub(/ *\([^)]*\)/,"",$2); n=split($2,a,", "); for(i=1;i<=n;i++) print a[i]}' \
  | sort -u > "$PROVIDES" || true

TOTAL=$(grep -Evc '^\s*(#|$)' "$INPUT" || echo 0)
log "Checking $TOTAL package names"

: > "$OK"; : > "$PRESENT"; : > "$MISSING"

while read -r pkg; do
  [[ -z "$pkg" || "$pkg" == \#* ]] && continue
  pkg="${pkg%%:*}"                       # strip :amd64 if present
  if grep -qxF "$pkg" "$INSTALLED"; then
    echo "$pkg" >> "$PRESENT"
  elif grep -qxF "$pkg" "$AVAIL" || grep -qxF "$pkg" "$PROVIDES"; then
    echo "$pkg" >> "$OK"
  else
    echo "$pkg" >> "$MISSING"
  fi
done < "$INPUT"

N_OK=$(wc -l < "$OK");      N_OK=${N_OK// /}
N_PRESENT=$(wc -l < "$PRESENT"); N_PRESENT=${N_PRESENT// /}
N_MISSING=$(wc -l < "$MISSING"); N_MISSING=${N_MISSING// /}

# -----------------------------------------------------------------------------
# For the missing ones, guess what they became. Three cheap heuristics that
# between them catch most real-world renames:
#   1. exact-ish prefix match      (python-foo    -> python3-foo)
#   2. apt-cache search on the stem (libfoo1      -> libfoo3)
#   3. transitional -> replacement  (foo          -> foo-ng)
# -----------------------------------------------------------------------------
{
  echo "Packages from the old VM that no longer exist in current Kali"
  echo "Generated: $(date -Is)"
  echo "============================================================"
  echo
  if [[ "$N_MISSING" -eq 0 ]]; then
    echo "None. Every package name still resolves."
  else
    while read -r pkg; do
      echo "--- $pkg"

      # Highest-value special case on an old VM: the python2 -> python3
      # migration renamed hundreds of packages by exactly one character.
      if [[ "$pkg" == python-* ]]; then
        py3="python3-${pkg#python-}"
        if grep -qxF "$py3" "$AVAIL"; then
          printf '    RENAME: %s  (python2 -> python3)\n' "$py3"
          continue
        fi
      fi

      # Second special case: transitional -ng packages (enum4linux -> -ng).
      if grep -qxF "${pkg}-ng" "$AVAIL"; then
        printf '    RENAME: %s-ng\n' "$pkg"
        continue
      fi

      stem=$(echo "$pkg" | sed -E 's/[0-9.]+$//; s/^(python|lib|golang)-//; s/-(dev|common|data|bin|utils)$//')
      # Candidates whose name contains the stem
      mapfile -t cands < <(grep -iE "(^|-)${stem}([0-9.-]|$)" "$AVAIL" 2>/dev/null | head -6)
      if [[ ${#cands[@]} -gt 0 ]]; then
        printf '    possible replacements: %s\n' "$(printf '%s ' "${cands[@]}")"
      else
        # Fall back to a description search
        desc=$(apt-cache search --names-only "$stem" 2>/dev/null | head -3 | awk '{print $1}' | tr '\n' ' ')
        if [[ -n "$desc" ]]; then
          printf '    name search: %s\n' "$desc"
        else
          printf '    no candidate found — likely dropped, or was from a third-party repo\n'
        fi
      fi
    done < "$MISSING"
  fi
} > "$REPORT"

# -----------------------------------------------------------------------------
echo
log "Results"
printf '  already installed : %5s  (nothing to do)\n' "$N_PRESENT"
printf '  installable       : %5s  -> %s\n' "$N_OK" "$OK"
printf '  no longer exists  : %5s  -> %s\n' "$N_MISSING" "$MISSING"
echo
if [[ "$N_MISSING" -gt 0 ]]; then
  warn "Read $REPORT — it suggests replacements for the missing names."
  warn "Most will be renames you can ignore or fix in a minute."
fi

# -----------------------------------------------------------------------------
if [[ "$APPLY" == "--apply" ]]; then
  if [[ "$N_OK" -eq 0 ]]; then
    log "Nothing to install."
    exit 0
  fi
  log "Installing $N_OK packages. This will take a while."
  # xargs in one transaction: apt resolves the whole set together, which is
  # both faster and better at dependency resolution than looping.
  # shellcheck disable=SC2002
  cat "$OK" | xargs sudo apt-get install -y --no-install-recommends
  log "Done. Re-run without --apply to confirm nothing is left."
else
  echo
  log "Report only — nothing was installed."
  log "To install: ./validate-package-list.sh $INPUT --apply"
  log "Or via the playbook: cp $OK roles/apt_tools/files/packages.txt && make apply"
fi
