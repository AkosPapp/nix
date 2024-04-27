.PHONY: help generate gen switch build commit sync update stage switch--show-trace

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build:                Build the new configuration"
	@echo "  commit:               Commit the changes"
	@echo "  generate:             Generate the code"
	@echo "  gen:                  Alias for generate"
	@echo "  help:                 Show this help message"
	@echo "  stage:                Stage the changes"
	@echo "  switch--show-trace:   Switch to the new configuration with --show-trace"
	@echo "  switch:               Switch to the new configuration"
	@echo "  sync:                 Commit and push the changes"
	@echo "  update:               Update the flake"
	@echo ""


gen: generate

generate:
	@echo "--- Generating the code ---"
	@./generate-modules.sh

switch: stage
	@echo "--- Switching to the new configuration ---"
	@$$([ "$$(whoami)" != "root" ] && echo -e "sudo") nixos-rebuild switch --flake .# && make commit

switch--show-trace: stage
	@echo "--- Switching to new configuration with --show-trace ---"
	@$$([ "$$(whoami)" != "root" ] && echo -e "sudo") nixos-rebuild switch --flake .# --show-trace && make commit

build: stage
	@echo "--- Building new configuration ---"
	@nixos-rebuild build --flake .# && make commit

iso: stage
	@echo "--- Building ISO ---"
	@nix build .#nixosConfigurations.iso.config.system.build.isoImage && make commit

update:
	@echo "--- Updating flake ---"
	nix flake update

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

