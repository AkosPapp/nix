
gen: generate

generate:
	@echo "Generating the code..."
	@./generate-modules.sh

switch: commit
	$$(if [ "$$(whoami)" != "root" ]; then echo -e "sudo "; fi;) nixos-rebuild switch --flake .#	
	#nixos-rebuild switch --flake .#

build: commit
	nixos-rebuild build --flake .#

commit:
	git commit -am "$$(date +%Y-%m-%d-%H-%M-%S)"
