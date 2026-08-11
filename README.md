# kali-forge

Reproducible Kali workstation for two machines — a desktop and a travel laptop — built from a declarative definition rather than a synced disk image.

The premise: **the VM is disposable, the definition is not.** Nothing of value lives only inside a running VM. Either the playbook can recreate it, or Syncthing carries it, or you moved it by hand once and wrote down that you did.

Designed for bulk transfer. If you have a years-old Kali VM with hundreds of accumulated packages, you carry the whole list across — no curation, no deciding what you "really" need.

---

## The three-way split

Getting this right is the whole game. Everything on your machine falls into exactly one bucket.

| Bucket | What | Where it lives | How it moves |
|---|---|---|---|
| **Rebuilt** | Packages, tools, dotfiles, system config | `packages.txt` + roles | `ansible-playbook site.yml` |
| **Synced** | Notes, engagement dirs, your scripts, loot | `~/vault` | Syncthing, continuously |
| **By hand** | SSH keys, VPN configs, Burp license, API tokens | Nowhere automatic | You, once, deliberately |

If you can't say which bucket a thing is in, it's going to be the thing that's missing when you're on a plane.

---

## Why bulk transfer is safe

A years-old VM will report something like 900 manually-installed packages. Carry all of them.

**Reinstalling what's already there costs nothing.** Most of that 900 is already in the Kali base image. `apt install` on a package that's present is a no-op — it doesn't re-download, doesn't reconfigure, doesn't take time.

**The one real failure mode is dead package names.** Over several years, packages get renamed (`python-requests` → `python3-requests`), merged, or dropped. And `apt install` is all-or-nothing: a single dead name in a list of 900 aborts the entire transaction with an unhelpful error.

That's what `validate-package-list.sh` exists for, and it's why the playbook filters the manifest against the live apt cache before installing. You can throw a five-year-old package list at this and it does the right thing — installs everything that still exists, tells you about the handful that don't.

Expect roughly 10–40 dead names out of 900. Most are python2 packages and versioned libs you don't care about.

---

## First time setup

### 1. Capture the old VM

Run this **inside your existing Kali VM**. Read-only, changes nothing.

```bash
chmod +x capture-kali-state.sh
./capture-kali-state.sh
```

The output you need is **`15-packages.txt`** — the full manual package list, one name per line, architecture suffixes already stripped.

Also grab `20-pipx.txt` and `25-go-tools.txt`. Those are the tools that drift silently, because you install them mid-box at 2am and never write them down. `25-go-tools.txt` recovers the original module path from each binary, so you get `github.com/projectdiscovery/nuclei/v3/cmd/nuclei` rather than just "nuclei".

### 2. Build the new VM

Download the official [Kali VMware image](https://www.kali.org/get-kali/#kali-virtual-machines), boot it, then:

```bash
git clone https://github.com/<you>/kali-forge.git ~/kali-forge
cd ~/kali-forge
```

### 3. Validate the package list against current Kali

Copy `15-packages.txt` over, then:

```bash
./scripts/validate-package-list.sh 15-packages.txt
```

You get four files back:

- `.present.txt` — already in the base image, nothing to do
- `.ok.txt` — exists in apt, will install cleanly
- `.missing.txt` — no longer exists, needs a decision
- `.report.txt` — the missing ones **with rename suggestions**

The report auto-detects the two most common rename patterns: python2→python3, and transitional `-ng` packages. For the rest it does a name search and offers candidates. Skim it — it's usually five minutes of work, and you can ignore most of it.

### 4. Install

```bash
cp 15-packages.ok.txt roles/apt_tools/files/packages.txt
./bootstrap.sh desktop
```

Or skip the playbook for the package step alone:

```bash
./scripts/validate-package-list.sh 15-packages.txt --apply
```

### 5. Build the laptop VM

Same image, same repo, same `packages.txt`:

```bash
./bootstrap.sh laptop
```

The `laptop` profile skips heavy GUI tools but keeps SecLists — you want wordlists offline on a plane more than you want a screen recorder.

### 6. Pair Syncthing

On both VMs, open `http://127.0.0.1:8384`, add each other as a remote device, share a folder with ID `vault` pointing at `~/vault`.

Turn on **Staggered File Versioning**. It's your undo button for the one time you `rm -rf` the wrong directory and it replicates in four seconds.

### 7. Snapshot

In VMware, snapshot both VMs as `clean-forge`. When a box requires installing something invasive, revert afterward rather than living with the residue.

---

## The autoremove trap

Worth calling out because it bites weeks later, long after you've forgotten what you did.

When you bulk-install, packages that arrive as dependencies get marked `auto`. Then one day you run `apt autoremove` and it silently deletes tools you meant to keep — because as far as apt knows, nothing depends on them anymore.

The playbook handles this by running `apt-mark manual` across the whole installed manifest after the install. If you install by hand with `--apply` instead, do the same:

```bash
sudo apt-mark manual $(cat 15-packages.ok.txt)
```

---

## Day-to-day discipline

**When you install something new**, install it normally to keep moving. Then add it to `roles/apt_tools/files/packages.txt` and commit. Not later — later never comes, and three months on you'll have two machines that both work and neither matches the repo.

A `git commit` in `~/kali-forge` is the atomic unit of "my setup changed."

Or let the machine do it. Re-run the capture on whichever VM you've been using and diff:

```bash
./scripts/capture-kali-state.sh
diff <(sort roles/apt_tools/files/packages.txt) kali-state-*/15-packages.txt
```

**On the other machine**, before you start work:

```bash
cd ~/kali-forge && git pull && make apply PROFILE=laptop
```

Re-running is cheap. Almost everything is idempotent; the expensive parts (Go builds, SecLists) check before acting.

**Before shutting down a VM:**

```bash
vault-status
```

Confirms Syncthing has flushed. A partial sync won't corrupt anything — you'll just land on the other machine missing your last twenty minutes of notes.

---

## Keeping the two in step over time

Kali is a rolling release, which is the one real weakness of this approach. Two VMs provisioned three weeks apart get different tool versions even from identical code.

Make upgrades an event, not a habit:

```bash
# On both machines, same day:
sudo apt update && sudo apt full-upgrade
cd ~/kali-forge && make apply
```

There's deliberately no `apt upgrade` in the playbook — an unattended upgrade during a rebuild is exactly how you get drift.

---

## Things the playbook deliberately will not do

Moved by hand, once per machine, never committed:

- **SSH keys** (`~/.ssh`) — generate per machine, or copy the pair. Never in the repo.
- **VPN configs** (HTB `.ovpn`) — regenerate from HTB when they expire.
- **Burp Suite Pro license** — tied to your account, activated interactively.
- **API tokens** (Shodan, VirusTotal, `gh auth`) — KeePassXC database in `~/vault`, paste them in.
- **GPG keys** — same reasoning as SSH.

`41-secrets-inventory.txt` from the capture lists which of these you have, by path only, never contents.

---

## Layout

```
kali-forge/
├── bootstrap.sh                    one command on a fresh VM
├── site.yml                        the playbook
├── group_vars/all.yml              curated groups + toggles
├── requirements.yml                Ansible collections
├── Makefile                        make apply / check / lint
├── scripts/
│   ├── capture-kali-state.sh       run inside the OLD VM
│   └── validate-package-list.sh    run on the NEW VM
└── roles/
    ├── base/                       hostname, locale, sudo, sysctl
    ├── vmware_guest/               open-vm-tools, HGFS
    ├── apt_tools/
    │   ├── files/packages.txt      ← THE BULK MANIFEST
    │   └── tasks/                  filter + install
    ├── lang_tools/                 pipx + go
    ├── opt_tools/                  git clones in /opt
    ├── dotfiles/                   zsh, tmux, nvim, git
    └── datasync/                   vault + Syncthing
```

Two package sources, both active:

- **`roles/apt_tools/files/packages.txt`** — the bulk manifest from your old VM. Hundreds of lines, unsorted, uncurated. This is the main path.
- **`group_vars/all.yml`** — curated groups (`apt_packages_core`, `_web`, `_ad`, `_gui`). Additive on top of the bulk list, and useful for things you want grouped and documented, or for a from-scratch minimal build.

---

## Useful commands

```bash
make check PROFILE=laptop     # dry run — what would change?
make tools                    # re-run tool roles only
make dotfiles                 # push a dotfile change, 10 seconds
make lint                     # before committing

ansible-playbook site.yml --tags apt --check --diff
ansible-playbook site.yml --tags opt -e "opt_force_update=true"
```

---

## Honest limitations

**This is more work than copying a VM image.** The payoff arrives at month three, when a drive dies, or you want a clean VM for a client engagement, or you need to know what's actually installed. If your setup genuinely never changes, an external SSD is the lower-effort answer and there's no shame in it.

**Rolling release means drift.** Mitigated above, not eliminated.

**GUI state doesn't capture well.** Burp's layout, your desktop panel arrangement, browser extensions — the playbook doesn't handle these, and honestly nothing does. Expect to redo them once per machine.

**Bulk transfer carries cruft forward.** Five years of experiments come along for the ride. That's the deliberate trade: disk is cheap, and your time deciding whether you still need `foo-legacy-utils` is not.
