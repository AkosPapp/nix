#!/bin/bash

# Configuration and Environment Setup
REPOS_ROOT="/root/repos"
FINAL_RESULT_ROOT="${REPOS_ROOT}/result"
SYSTEMS=("x86_64-linux" "aarch64-linux")

# Set systems for the Nix expression to use
SYSTEMS_JSON="$(echo "${SYSTEMS[@]}" | tr " " ",")"

# Exit immediately if a command exits with a non-zero status.
set -e

# A function to generate the list of build targets for a flake path.
# Output is a space-separated string of full target references.
generate_targets() {
    local flake_path="$1"
    
    nix eval --impure --raw --expr "
      let
        flake = builtins.getFlake \"${flake_path}\";
        systems = builtins.fromJSON \"[${systems_json}]\"; # From the shell environment

        # Function to generate targets for 'packages' or 'devShells'
        getSystemTargets = attrName: builtins.concatMap (system:
          let
            attrSet = (flake.\${attrName}.\${system} or {});
            names = builtins.attrNames attrSet;
          in
            # Output format: '.#<attrName>.<system>.<name>'
            map (name: \"${flake_path}#\${attrName}.\${system}.\${name}\") names
        ) systems;

        # NixOS targets: Output format: '.#nixosConfigurations.<name>.config.system.build.toplevel'
        nixosConfigs = flake.nixosConfigurations or {};
        nixosNames = builtins.attrNames nixosConfigs;
        nixosTargets = map (name: \"${flake_path}#nixosConfigurations.\${name}.config.system.build.toplevel\") nixosNames;

      in
        # Combine and print targets separated by spaces
        builtins.concatStringsSep \" \" (
          nixosTargets ++ 
          (getSystemTargets \"packages\") ++ 
          (getSystemTargets \"devShells\")
        )
    " --argstr systems_json "${SYSTEMS_JSON}"
}

# --- Main Logic ---

echo "Starting Nix Flake Repository Update and Build Process."
echo "--------------------------------------------------------"

# Find all potential flake directories under /root/*/
# Excluding the results directory and hidden directories (using -name ".*" -prune)
while true; do
    find "${REPOS_ROOT}" -mindepth 2 -maxdepth 2 -type d \
      -not -path "${FINAL_RESULT_ROOT}/*" \
      -not -name ".*" | while read -r repo_path; do

        # Ensure it looks like a flake directory before proceeding
        if [ ! -f "${repo_path}/flake.nix" ]; then
            echo "Skipping ${repo_path}: No flake.nix found."
            continue
        fi

        # Extract owner and repo name for output linking
        owner=$(basename "$(dirname "${repo_path}")")
        repo=$(basename "${repo_path}")
        owner_repo="${owner}/${repo}"

        echo -e "\n---> Processing: ${owner_repo} (Path: ${repo_path})"

        # Check if it's a git repo before pulling
        if [ ! -d "${repo_path}/.git" ]; then
            echo "-> WARNING: Not a git repository. Skipping pull, but will proceed with build."
            PULL_CHANGED="true" # Force build if not a git repo
        else
            cd "${repo_path}" || { echo "Failed to cd to ${repo_path}"; continue; }

            # 1. Try to pull changes (capturing output for change detection)
            PULL_OUTPUT=$(git pull --ff-only 2>&1)
            PULL_STATUS=$?

            if [ ${PULL_STATUS} -ne 0 ]; then
                echo "-> Git pull failed (Status ${PULL_STATUS}). Skipping build."
                echo "${PULL_OUTPUT}"
                continue
            fi

            # 2. Check if any changes were applied by looking for fast-forward keywords
            if echo "${PULL_OUTPUT}" | grep -q 'Fast-forward\|Updating'; then
                PULL_CHANGED="true"
                echo "-> Changes detected via Fast-forward. Starting build."
            else
                PULL_CHANGED="false"
                echo "-> No changes detected or already up-to-date. Skipping build."
            fi
        fi

        # 3. Build if changes were detected (or forced)
        if [ "${PULL_CHANGED}" == "true" ]; then

            # Get target build list
            TARGETS_LIST=$(generate_targets "${repo_path}")

            # Ensure target directory exists for this repo
            REPO_RESULT_DIR="${FINAL_RESULT_ROOT}/${owner}/${repo}"
            rm -rf "${REPO_RESULT_DIR}"
            mkdir -p "${REPO_RESULT_DIR}"

            # Iterate over each target and build it separately
            for target_ref in ${TARGETS_LIST}; do

                # Calculate the clean symlink name based on the target reference
                out_name=""
                if [[ "$target_ref" == *".nixosConfigurations."* ]]; then
                    # Example: .#nixosConfigurations.host1.config.system.build.toplevel -> nixosConfigs/host1
                    # The output link is simplified here to match the NixOS config name
                    out_name=$(echo "$target_ref" | sed -E "s/.*nixosConfigurations\.([^\.]+)\.config.*/nixosConfigs\/\1/")
                else
                    # Example: .#packages.x86_64-linux.hello -> x86_64-linux/packages/hello
                    # Example: .#devShells.aarch64-linux.default -> aarch64-linux/devShells/default
                    # The regex captures attrName, system, and final name
                    out_name=$(echo "$target_ref" | sed -E "s/\.#([^\.]+)\.([^\.]+)\.([^\.]+)/\2\/\1\/\3/")
                fi

                # Final symlink path
                out_link_path="${REPO_RESULT_DIR}/$(cut -d'#' -f2- <<< "${out_name}")"

                echo "   -> Building ${target_ref} (Link: ${out_link_path})"

                # Run the build command
                # We use --no-warn-dirty and explicitly reference the path to the flake
                nix build --no-warn-dirty --out-link "${out_link_path}" "${target_ref}" \
                    || echo "   !!! WARNING: Build failed for ${target_ref} in ${owner_repo}. Check logs."

            done

            echo "-> Build process complete for ${owner_repo}."
        fi

    done
    sleep 60
done