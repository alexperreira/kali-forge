#!/usr/bin/env bash
#
# bootstrap.sh — the only thing you run by hand on a fresh Kali VM.
#
# Installs Ansible, pulls the required collections, and hands off to the
# playbook. Safe to re-run.
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/kali-forge/main/bootstrap.sh | bash
#
# or, if you've already cloned:
#
#   ./bootstrap.sh [desktop|laptop]
#
set -euo pipefail

PROFILE="${1:-desktop}"
REPO_URL="${FORGE_REPO:-https://github.com/CHANGEME/kali-forge.git}"
REPO_DIR="${FORGE_DIR:-$HOME/kali-forge}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "Do not run this as root. It escalates where needed."

case "$PROFILE" in
  desktop|laptop) ;;
  *) die "profile must be 'desktop' or 'laptop', got '$PROFILE'" ;;
esac

log "Profile: $PROFILE"

# -----------------------------------------------------------------------------
log "Installing Ansible"
sudo apt-get update -qq
sudo apt-get install -y -qq ansible git python3-pip

# -----------------------------------------------------------------------------
if [[ -d "$REPO_DIR/.git" ]]; then
  log "Repo already present at $REPO_DIR — pulling"
  git -C "$REPO_DIR" pull --ff-only || log "pull skipped (local changes)"
elif [[ -f "$(dirname "$0")/site.yml" ]]; then
  REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
  log "Running from existing checkout at $REPO_DIR"
else
  log "Cloning $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# -----------------------------------------------------------------------------
log "Installing Ansible collections"
ansible-galaxy collection install -r requirements.yml

# -----------------------------------------------------------------------------
log "Running the playbook (this takes 15-30 minutes on first run)"
ansible-playbook site.yml -e "forge_profile=$PROFILE" "${@:2}"

# -----------------------------------------------------------------------------
cat <<'EOF'

Done.

Next steps, in order:
  1. Log out and back in       (shell change + group membership)
  2. Open http://127.0.0.1:8384 and pair Syncthing with your other VM
  3. Copy over the by-hand items: SSH keys, VPN configs, Burp license
     (see README section "Things the playbook deliberately will not do")
  4. Snapshot the VM in VMware and name it "clean-forge"

EOF
