.PHONY: help switch build commit sync update stage switch--show-trace fmt

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build:                Build the new configuration"
	@echo "  commit:               Commit the changes"
	@echo "  help:                 Show this help message"
	@echo "  stage:                Stage the changes"
	@echo "  switch--show-trace:   Switch to the new configuration with --show-trace"
	@echo "  switch:               Switch to the new configuration"
	@echo "  sync:                 Commit and push the changes"
	@echo "  update:               Update the flake"
	@echo "  upgrade:              Upgrade the flake"
	@echo "  iso:                  Build the ISO"
	@echo "  upload-remote:        Upload the flake to a remote server"
	@echo "  install-remote:       Install the flake on a remote server"
	@echo ""

fmt:
	@echo "--- Formatting the code ---"
	@nix fmt .

switch: fmt stage
	@echo "--- Switching to the new configuration ---"
	@$$([ "$$(whoami)" != "root" ] && echo -e "sudo") nixos-rebuild switch --flake .# --impure && make commit

switch--show-trace: stage
	@echo "--- Switching to new configuration with --show-trace ---"
	@$$([ "$$(whoami)" != "root" ] && echo -e "sudo") nixos-rebuild switch --flake .# -impure --show-trace && make commit

build: stage
	@echo "--- Building new configuration ---"
	@nixos-rebuild build --flake .# && make commit

iso: stage
	@echo "--- Building ISO ---"
	@nix build .#nixosConfigurations.iso.config.system.build.isoImage

update:
	@echo "--- Updating flake ---"
	nix flake update

upgrade:
	@echo "--- Upgrading flake ---"
	make commit
	make update
	make fmt
	make switch
	make sync

stage:
	@echo "--- Staging changes ---"
	@git add .

commit: stage
	@echo "--- Committing changes ---"
	@[ "$$(git status --porcelain)" ] && git commit -am "$$(date +%Y-%m-%d-%H-%M-%S)" || echo "No changes to commit!"

sync: commit
	@echo "--- Syncing changes ---"
	@git pull
	@git push

upload-remote:
	@if [ "$(IP)" = "" ]; then \
		echo "IP not set"; \
		echo "Usage: make IP=<ip> upload-remote"; \
		exit 1; \
	fi; \
	echo "Uploading Flake"; \
	rsync -auzv ./* root@$(IP):/tmp/nixconfig --exclude .git --exclude result

install-remote:
	@if [ "$(IP)" = "" ]; then \
		echo "IP not set"; \
		echo "Usage: make IP=<ip> CONFIG=<config> install-remote"; \
		exit 1; \
	fi; \
	if [ "$(CONFIG)" = "" ]; then \
		echo "CONFIG not set"; \
		echo "Usage: make IP=<ip> CONFIG=<config> install-remote"; \
		exit 1; \
	fi; \
	make IP=$(IP) upload-remote; \
	echo "Installing Flake"; \
	ssh root@$(IP) 'nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko /tmp/nixconfig/hosts/$(CONFIG)/disko.nix' && \
	ssh root@$(IP) 'nixos-install --flake /tmp/nixconfig#$(CONFIG) -impure'; \
