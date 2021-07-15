#! /usr/bin/env bash
set -euo pipefail
# Args
flake_dir=$1
flake_attr=$2
cache_flake_attr=$3
shift 3

# attr of derivation
# flake_dir="."
# flake_attr="homeManagerConfigurations.nixos.activationPackage"
# cache_flake_attr="installMedia.iso.config.nix"

# NOTE: need impure because flake path is local (and mutable?)
command=(nix eval --json --impure --show-trace --expr "
  let
    flake = builtins.getFlake (toString ${flake_dir}/.);
    concatWithSpaceSeparator = builtins.concatStringsSep \" \";
  in
  {
    inherit (builtins) currentSystem;
    substituters = concatWithSpaceSeparator flake.${cache_flake_attr}.binaryCaches;
    trusted-public-keys = concatWithSpaceSeparator flake.${cache_flake_attr}.binaryCachePublicKeys;
    drv_path = flake.${flake_attr}.drvPath;
    out_path = flake.${flake_attr};
  }")

# add all extra CLI args as extra build arguments
command+=("$@")

# Instantiate
echo "running (instantiating): ${NIX_PATH:+NIX_PATH=$NIX_PATH} ${command[*]@Q}" -A out_path >&2
first_output=$("${command[@]}")

# need to build first to check the requirements in store
nix build --show-trace "${flake_dir}#${flake_attr}"
# Get references for diff
out_path=$(nix eval --json --impure --show-trace "${flake_dir}#${flake_attr}" | tr -d '"')
second_output=$(nix-store -qR "${out_path}" \
  | sort -t'-' -k 2 \
  | sed 's:/nix/store/[^-]*-: :' \
  | jq --slurp --raw-input '. | { references: .}')

# echo $second_output
echo "${first_output} ${second_output}" | jq -s add
