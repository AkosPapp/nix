.PHONY: help generate gen switch build commit sync

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  generate: Generate the code"
	@echo "  switch:   Switch to the new configuration"
	@echo "  build:    Build the new configuration"
	@echo "  commit:   Commit the changes"
	@echo "  sync:     Commit and push the changes"
	@echo "  help:     Show this help message"


gen: generate

generate:
	@echo "Generating the code..."
	@./generate-modules.sh

switch: commit
	@echo "Switching to the new configuration..."
	@$$([ "$$(whoami)" != "root" ] && echo -e "sudo") nixos-rebuild switch --flake .#	

switch--show-trace: commit
	@echo "Switching to the new configuration..."
	@$$([ "$$(whoami)" != "root" ] && echo -e "sudo") nixos-rebuild switch --flake .# --show-trace

build: commit
	@echo "Building the new configuration..."
	@nixos-rebuild build --flake .#

commit:
	@echo "Committing the changes..."
	@[ "$$(git status --porcelain)" ] && git commit -am "$$(date +%Y-%m-%d-%H-%M-%S)" || echo "No changes to commit!"

sync: commit
	@echo "Syncing the changes..."
	@git pull
	@git push
