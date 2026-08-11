#!/usr/bin/env bash
#
# capture-kali-state.sh
#
# Run this INSIDE your existing Kali VM. It inventories everything that makes
# that VM "yours" and writes a report you can hand back to Claude (or read
# yourself) to generate the Ansible roles.
#
# It is READ-ONLY. It installs nothing, changes nothing, and touches no file
# outside its own output directory.
#
#   chmod +x capture-kali-state.sh
#   ./capture-kali-state.sh
#
# Output: ./kali-state-<hostname>-<date>/ plus a .tar.gz of the same.
#
set -uo pipefail

OUTDIR="kali-state-$(hostname)-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUTDIR"

# The user whose environment we're capturing. Works whether you run this
# directly, under sudo, or from a shell that doesn't export USER.
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }

# Run a command; write stdout to a file; never abort the script on failure.
grab() {
  local dest="$1"; shift
  if command -v "$1" >/dev/null 2>&1 || [[ "$1" == "bash" ]]; then
    "$@" > "$OUTDIR/$dest" 2>/dev/null || warn "partial/failed: $* -> $dest"
  else
    echo "# $1 not installed" > "$OUTDIR/$dest"
  fi
}

# ----------------------------------------------------------------------------
# 1. System identity and base image
# ----------------------------------------------------------------------------
log "System identity"
{
  echo "=== os-release ==="; cat /etc/os-release
  echo; echo "=== kernel ==="; uname -a
  echo; echo "=== kali version ==="; cat /etc/debian_version 2>/dev/null
  echo; echo "=== hostname ==="; hostname
  echo; echo "=== primary user ==="; id "$TARGET_USER"
  echo; echo "=== shell ==="; getent passwd "$TARGET_USER" | cut -d: -f7
  echo; echo "=== desktop session ==="; echo "${XDG_CURRENT_DESKTOP:-none}"
  echo; echo "=== cpu/mem ==="; nproc; free -h
  echo; echo "=== disk ==="; df -h /
  echo; echo "=== virt platform ==="; systemd-detect-virt 2>/dev/null
} > "$OUTDIR/00-system.txt"

# ----------------------------------------------------------------------------
# 2. APT — the important one.
#
# The primary output is 15-packages.txt: the FULL list of manually-installed
# packages, ready to feed straight into the new VM. No curation.
#
# Reinstalling something the base image already has is a no-op, so there is no
# cost to carrying the whole list across. The only real failure mode is a
# package name that no longer exists in current Kali, and that's what
# validate-package-list.sh handles on the receiving end.
#
# The subtracted "extra" list is still produced, but as a reading aid — if you
# ever want to know what you personally added on top of the base image, that's
# the file. It is not the install list.
# ----------------------------------------------------------------------------
log "APT packages (this is the slow part, ~30s)"

# Every package currently installed, with versions. Reference only.
dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$OUTDIR/10-apt-all.tsv" 2>/dev/null

# Packages marked 'manual' — installed deliberately, not pulled in as a dep.
apt-mark showmanual 2>/dev/null | sort -u > "$OUTDIR/11-apt-manual.txt"

# ---- THE INSTALL LIST -------------------------------------------------------
# Strip architecture qualifiers (foo:amd64 -> foo), drop blanks and comments.
# This is what you carry to the new machine.
sed -E 's/:[a-z0-9]+$//' "$OUTDIR/11-apt-manual.txt" \
  | grep -Ev '^\s*(#|$)' \
  | sort -u > "$OUTDIR/15-packages.txt"

# Kali metapackages present (kali-linux-default, -headless, -large, etc.)
grep -E '^kali-(linux|tools|desktop|defaults)' "$OUTDIR/11-apt-manual.txt" \
  > "$OUTDIR/12-kali-metapackages.txt" 2>/dev/null || true

# Manual packages MINUS anything a Kali metapackage would have brought in.
# Reading aid, not the install list — see the comment block above.
if command -v apt-cache >/dev/null 2>&1; then
  META_DEPS=$(mktemp)
  while read -r meta; do
    [[ -z "$meta" ]] && continue
    apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances \
      "$meta" 2>/dev/null | grep -v '^ ' | grep -v '^<' | tr -d ' '
  done < "$OUTDIR/12-kali-metapackages.txt" | sort -u > "$META_DEPS"

  if [[ -s "$META_DEPS" ]]; then
    comm -23 <(sort -u "$OUTDIR/15-packages.txt") "$META_DEPS" \
      > "$OUTDIR/13-apt-manual-extra.txt"
  else
    cp "$OUTDIR/15-packages.txt" "$OUTDIR/13-apt-manual-extra.txt"
  fi
  rm -f "$META_DEPS"
fi

# Also capture the auto-installed set. Not needed for a rebuild (apt resolves
# dependencies itself), but occasionally useful when diagnosing why something
# is present on the old machine and absent on the new one.
apt-mark showauto 2>/dev/null | sort -u > "$OUTDIR/16-apt-auto.txt"

# Third-party repos and pinning — these break rebuilds if forgotten.
{
  echo "=== /etc/apt/sources.list ==="; cat /etc/apt/sources.list 2>/dev/null
  echo; echo "=== /etc/apt/sources.list.d/ ==="
  for f in /etc/apt/sources.list.d/*; do
    [[ -e "$f" ]] || continue
    echo "--- $f ---"; cat "$f"
  done
  echo; echo "=== /etc/apt/preferences.d/ ==="
  for f in /etc/apt/preferences.d/*; do
    [[ -e "$f" ]] || continue
    echo "--- $f ---"; cat "$f"
  done
  echo; echo "=== signing keys ==="
  ls -la /etc/apt/keyrings /etc/apt/trusted.gpg.d 2>/dev/null
} > "$OUTDIR/14-apt-sources.txt"

# ----------------------------------------------------------------------------
# 3. Language-ecosystem tooling — the stuff apt doesn't know about
# ----------------------------------------------------------------------------
log "Language-ecosystem tools (pipx, pip, go, cargo, npm, gem)"

grab 20-pipx.txt        pipx list
grab 21-pip-user.txt    bash -c 'pip list --user --format=freeze 2>/dev/null || pip3 list --user --format=freeze 2>/dev/null'
grab 22-cargo.txt       cargo install --list
grab 23-npm-global.txt  npm ls -g --depth=0
grab 24-gem.txt         gem list --local --no-versions

# Go tools don't have a registry — they're just binaries in ~/go/bin.
# Capture the binary names AND try to recover their module paths.
{
  GOBIN="${GOBIN:-$HOME/go/bin}"
  if [[ -d "$GOBIN" ]]; then
    echo "=== binaries in $GOBIN ==="
    ls -1 "$GOBIN"
    echo
    echo "=== recovered module paths (go version -m) ==="
    for b in "$GOBIN"/*; do
      [[ -x "$b" && -f "$b" ]] || continue
      path=$(go version -m "$b" 2>/dev/null | awk '$1=="path"{print $2; exit}')
      mod=$(go version -m "$b" 2>/dev/null | awk '$1=="mod"{print $2"@"$3; exit}')
      printf '%-28s %-55s %s\n' "$(basename "$b")" "${path:-?}" "${mod:-?}"
    done
  else
    echo "# no $GOBIN directory"
  fi
} > "$OUTDIR/25-go-tools.txt" 2>/dev/null

# ----------------------------------------------------------------------------
# 4. Tools installed by hand — git clones, /opt drops, ~/tools
# ----------------------------------------------------------------------------
log "Hand-installed tools (/opt, ~/tools, ~/.local/bin)"
{
  for d in /opt "$HOME/tools" "$HOME/Tools" "$HOME/opt" "$HOME/git" "$HOME/repos"; do
    [[ -d "$d" ]] || continue
    echo "=== $d ==="
    find "$d" -maxdepth 2 -name .git -type d 2>/dev/null | while read -r g; do
      repo="${g%/.git}"
      url=$(git -C "$repo" remote get-url origin 2>/dev/null)
      ref=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
      printf '%-45s %s @ %s\n' "$repo" "${url:-<no remote>}" "${ref:-?}"
    done
    echo "--- non-git entries ---"
    find "$d" -maxdepth 1 -mindepth 1 2>/dev/null | while read -r e; do
      [[ -d "$e/.git" ]] || echo "$e"
    done
    echo
  done

  echo "=== ~/.local/bin ==="
  ls -la "$HOME/.local/bin" 2>/dev/null

  echo; echo "=== custom entries in /usr/local/bin ==="
  ls -la /usr/local/bin 2>/dev/null
} > "$OUTDIR/30-manual-tools.txt"

# ----------------------------------------------------------------------------
# 5. Dotfiles and shell config
# ----------------------------------------------------------------------------
log "Dotfiles"
DOTDIR="$OUTDIR/40-dotfiles"
mkdir -p "$DOTDIR"

DOTFILES=(
  .zshrc .zshenv .zprofile .zsh_aliases
  .bashrc .bash_aliases .profile .inputrc
  .tmux.conf .vimrc .gitconfig .gitignore_global
  .curlrc .wgetrc .netrc.template
)
for f in "${DOTFILES[@]}"; do
  [[ -f "$HOME/$f" ]] && cp "$HOME/$f" "$DOTDIR/${f#.}" 2>/dev/null
done

DOTDIRS=(
  .config/nvim .config/kitty .config/alacritty .config/terminator
  .config/Code/User .config/tmux .config/starship.toml
  .oh-my-zsh/custom .vim/after .zsh
)
for d in "${DOTDIRS[@]}"; do
  if [[ -d "$HOME/$d" ]]; then
    mkdir -p "$DOTDIR/$(dirname "$d")"
    cp -r "$HOME/$d" "$DOTDIR/$d" 2>/dev/null
  fi
done

# Burp/ZAP/Metasploit config — note presence, do NOT copy (contains secrets).
{
  echo "# Presence check only. These are NOT copied — they contain licenses,"
  echo "# API keys, and session state. Handle them manually."
  for p in \
    "$HOME/.BurpSuite" "$HOME/.java/.userPrefs/burp" \
    "$HOME/ZAP" "$HOME/.ZAP" \
    "$HOME/.msf4" "$HOME/.sqlmap" "$HOME/.john" \
    "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.azure" \
    "$HOME/.docker" "$HOME/.kube" "$HOME/.config/gh"
  do
    [[ -e "$p" ]] && printf '%-40s EXISTS  (%s)\n' "$p" "$(du -sh "$p" 2>/dev/null | cut -f1)"
  done
} > "$OUTDIR/41-secrets-inventory.txt"

# ----------------------------------------------------------------------------
# 6. System-level config that isn't a dotfile
# ----------------------------------------------------------------------------
log "System config"
{
  echo "=== enabled systemd units (non-default) ==="
  systemctl list-unit-files --state=enabled --no-pager 2>/dev/null

  echo; echo "=== enabled user units ==="
  systemctl --user list-unit-files --state=enabled --no-pager 2>/dev/null

  echo; echo "=== /etc/hosts ==="; cat /etc/hosts
  echo; echo "=== /etc/resolv.conf ==="; cat /etc/resolv.conf 2>/dev/null
  echo; echo "=== sudoers.d ==="; ls -la /etc/sudoers.d 2>/dev/null
  echo; echo "=== groups for user ==="; groups "$TARGET_USER"
  echo; echo "=== crontab (user) ==="; crontab -l 2>/dev/null
  echo; echo "=== timezone/locale ==="; timedatectl 2>/dev/null; locale
  echo; echo "=== sysctl overrides ==="; ls -la /etc/sysctl.d 2>/dev/null
  echo; echo "=== open-vm-tools ==="; dpkg -l | grep -i vm-tools
} > "$OUTDIR/50-system-config.txt"

# ----------------------------------------------------------------------------
# 7. Wordlists and data — big, and worth NOT rebuilding from scratch
# ----------------------------------------------------------------------------
log "Wordlists and data volume"
{
  for d in /usr/share/wordlists /usr/share/seclists "$HOME/wordlists" \
           "$HOME/notes" "$HOME/htb" "$HOME/HTB" "$HOME/engagements" "$HOME/loot"
  do
    [[ -e "$d" ]] || continue
    printf '%-38s %8s  %s files\n' "$d" \
      "$(du -sh "$d" 2>/dev/null | cut -f1)" \
      "$(find "$d" -type f 2>/dev/null | wc -l)"
  done
} > "$OUTDIR/60-data-volumes.txt"

# ----------------------------------------------------------------------------
# 8. Summary
# ----------------------------------------------------------------------------
{
  echo "Kali state capture"
  echo "Host:      $(hostname)"
  echo "Date:      $(date -Is)"
  echo "Kali:      $(grep VERSION= /etc/os-release | cut -d'"' -f2)"
  echo
  echo "Packages installed (total):   $(wc -l < "$OUTDIR/10-apt-all.tsv")"
  echo "Marked manual:                $(wc -l < "$OUTDIR/11-apt-manual.txt")"
  echo "--> INSTALL LIST (15-packages.txt): $(wc -l < "$OUTDIR/15-packages.txt")"
  echo "Of those, beyond metapackages: $(wc -l < "$OUTDIR/13-apt-manual-extra.txt" 2>/dev/null || echo '?')"
  echo "Kali metapackages:            $(tr '\n' ' ' < "$OUTDIR/12-kali-metapackages.txt")"
  echo
  # grep -c prints 0 and exits 1 when there are no matches; no `|| echo 0`
  # fallback here or it prints the count twice.
  echo "Go tools:    $(grep -c . "$OUTDIR/25-go-tools.txt" 2>/dev/null) lines captured"
  echo "pipx:        $(grep -c 'package' "$OUTDIR/20-pipx.txt" 2>/dev/null) entries"
  echo
  echo "NEXT STEP"
  echo "  Copy 15-packages.txt to the new VM and run:"
  echo "    ./validate-package-list.sh 15-packages.txt"
  echo "  It reports which names still exist in current Kali before you install."
} | tee "$OUTDIR/SUMMARY.txt"

tar czf "$OUTDIR.tar.gz" "$OUTDIR"
echo
log "Done."
log "Directory: $OUTDIR/"
log "Archive:   $OUTDIR.tar.gz  ($(du -sh "$OUTDIR.tar.gz" | cut -f1))"
echo
warn "Before sharing: skim 40-dotfiles/ for anything with a token in it."
warn "41-secrets-inventory.txt lists paths only, never contents."
