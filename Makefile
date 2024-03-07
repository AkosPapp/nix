
gen: generate

generate:
	@echo "Generating the code..."
	@./generate-modules.sh

switch: commit
	nixos-rebuild switch --flake .#

build: commit
	nixos-rebuild build --flake .#

commit:
	git commit -am "$$(date +%Y-%m-%d-%H-%M-%S)"
