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

switch: stage
	@echo "Switching to the new configuration..."
	@$$([ "$$(whoami)" != "root" ] && echo -e "sudo") nixos-rebuild switch --flake .# && make commit

switch--show-trace: stage
	@echo "Switching to the new configuration..."
	@$$([ "$$(whoami)" != "root" ] && echo -e "sudo") nixos-rebuild switch --flake .# --show-trace && make commit

build: stage
	@echo "Building the new configuration..."
	@nixos-rebuild build --flake .# && make commit

stage:
	@git add .

commit: stage
	@echo "Committing the changes..."
	@[ "$$(git status --porcelain)" ] && git commit -am "$$(date +%Y-%m-%d-%H-%M-%S)" || echo "No changes to commit!"

sync: commit
	@echo "Syncing the changes..."
	@git pull
	@git push
