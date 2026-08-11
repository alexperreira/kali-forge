# kali-forge zsh fragment
# Managed by Ansible. Edit in the repo, not here — this file is overwritten.

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------
typeset -U path
path=(
  "$HOME/.local/bin"
  "$HOME/bin"
  "$HOME/go/bin"
  "/opt/PEASS-ng/linPEAS"
  $path
)
export PATH

export GOPATH="$HOME/go"
export EDITOR=nvim
export VISUAL=nvim
export PAGER=less
export LESS='-R -F -X'

# ---------------------------------------------------------------------------
# Vault — the synced data volume
# ---------------------------------------------------------------------------
export VAULT="$HOME/vault"
export NOTES="$VAULT/notes"
export ENGAGEMENTS="$VAULT/engagements"
export WORDLISTS="/usr/share/seclists"

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------
alias ll='ls -lah --group-directories-first'
alias v=nvim
alias cat='batcat --paging=never --style=plain'
alias fd='fdfind'
alias ports='ss -tulpn'
alias myip='curl -s ifconfig.me; echo'
alias serve='python3 -m http.server 8000'
alias vault='cd $VAULT'

# Kali's tmux is more useful with a default session
alias tm='tmux new-session -A -s main'

# ---------------------------------------------------------------------------
# Engagement scaffolding
#
# `box hostname` creates a consistent directory layout under the synced vault
# and drops you into it. Consistency here is what makes notes searchable
# months later.
# ---------------------------------------------------------------------------
box() {
  if [[ -z "$1" ]]; then
    echo "usage: box <name>" >&2
    return 1
  fi
  local d="$ENGAGEMENTS/$1"
  mkdir -p "$d"/{scans,loot,exploits,screenshots}
  if [[ ! -f "$d/notes.md" ]]; then
    {
      printf '# %s\n\n' "$1"
      printf -- '- started: %s\n' "$(date +%F)"
      printf -- '- target:  \n- creds:   \n\n'
      printf '## Recon\n\n## Foothold\n\n## Privesc\n\n## Loot\n'
    } > "$d/notes.md"
  fi
  cd "$d" || return
}

# Quick full-port then targeted scan. Writes into the current box dir.
recon() {
  local ip="${1:?usage: recon <ip>}"
  mkdir -p scans
  echo "[*] full TCP sweep -> scans/all-ports.txt"
  sudo nmap -p- --min-rate 5000 -T4 -oN scans/all-ports.txt "$ip"
  local ports
  ports=$(grep -oP '^\d+(?=/tcp\s+open)' scans/all-ports.txt | paste -sd,)
  if [[ -n "$ports" ]]; then
    echo "[*] service scan on $ports -> scans/services.txt"
    sudo nmap -p"$ports" -sCV -oN scans/services.txt "$ip"
  else
    echo "[!] no open TCP ports found"
  fi
}

# Decode/encode helpers you'll reach for constantly
b64d() { echo -n "$1" | base64 -d; echo; }
b64e() { echo -n "$1" | base64 -w0; echo; }
urld() { python3 -c "import sys,urllib.parse as u;print(u.unquote(sys.argv[1]))" "$1"; }
urle() { python3 -c "import sys,urllib.parse as u;print(u.quote(sys.argv[1]))" "$1"; }

# ---------------------------------------------------------------------------
# Prompt marker so you always know which VM you're on
# ---------------------------------------------------------------------------
if [[ -n "$FORGE_PROFILE" ]]; then
  RPROMPT="%F{240}[$FORGE_PROFILE]%f"
fi

# ---------------------------------------------------------------------------
# fzf
# ---------------------------------------------------------------------------
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && \
  source /usr/share/doc/fzf/examples/key-bindings.zsh
[ -f /usr/share/doc/fzf/examples/completion.zsh ] && \
  source /usr/share/doc/fzf/examples/completion.zsh

# ---------------------------------------------------------------------------
# History that survives and doesn't get clobbered by parallel shells
# ---------------------------------------------------------------------------
HISTSIZE=100000
SAVEHIST=100000
setopt INC_APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_REDUCE_BLANKS
