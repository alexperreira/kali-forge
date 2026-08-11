.PHONY: help apply check tools dotfiles data lint syntax diff snapshot

PROFILE ?= desktop
PLAY    := ansible-playbook site.yml -e "forge_profile=$(PROFILE)"

help:
	@echo "kali-forge"
	@echo ""
	@echo "  make apply     PROFILE=desktop|laptop   run everything"
	@echo "  make check     PROFILE=...              dry run, show what would change"
	@echo "  make tools                              re-run tool roles only"
	@echo "  make dotfiles                           re-run dotfiles only"
	@echo "  make data                               re-run vault/syncthing only"
	@echo "  make lint                               ansible-lint + yamllint"
	@echo "  make syntax                             parse check, no execution"
	@echo ""
	@echo "current profile: $(PROFILE)"

apply:
	$(PLAY)

check:
	$(PLAY) --check --diff

tools:
	$(PLAY) --tags tools

dotfiles:
	$(PLAY) --tags dotfiles

data:
	$(PLAY) --tags data

syntax:
	ansible-playbook site.yml --syntax-check

lint:
	ansible-lint site.yml roles/
	yamllint .
