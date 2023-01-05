#!/usr/bin/env bash
# nixos-deploy deploys a nixos-instantiate-generated drvPath to a target host
#
# Usage: nixos-deploy.sh <drvPath> <outPath> <host> <port> <build-on-target> <activate-script-path> <activate-action> [<build-opts>] ignoreme
set -euo pipefail

### Defaults ###

buildArgs=(
  --option extra-binary-caches https://cache.nixos.org/
)
# will be set later
sshOpts=(
  -o "ControlMaster=auto"
  -o "ControlPersist=60"
  # Avoid issues with IP re-use. This disable TOFU security.
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=/dev/null"
  -o "GlobalKnownHostsFile=/dev/null"
  # interactive authentication is not possible
  -o "BatchMode=yes"
  # verbose output for easier debugging set based on flag later
)

###  Argument parsing ###

drvPath="${1}"
outPath="${2}"
localDeploy="${3}"
targetHost="${4}"
targetPort="${5}"
sshPrivateKey="${6}"
verboseOutput="${7}"
activateActions="${8}"
activateScriptPath="${9}"
buildOnTarget="${10}"
nixProfile="${11}"
escalateDeployForProfile="${12}"
escalateDeployForCommands="${13}"
escalateDeployForGC="${14}"
deleteOlderThan="${15}"
shift 15


# Set ssh verbosity if toggled
if [[ "${verboseOutput:-false}" == "true" ]]; then
  sshOpts+=(-v)
fi

profile="/nix/var/nix/profiles/${nixProfile}"

# remove the last argument
set -- "${@:1:$(($# - 1))}"
buildArgs+=("$@")

sshOpts+=( -p "${targetPort}" )

workDir=$(mktemp -d)
trap 'rm -rf "$workDir"' EXIT

if [[ -n "${sshPrivateKey}" && "${sshPrivateKey}" != "-" ]]; then
  sshPrivateKeyFile="$workDir/ssh_key"
  echo "$sshPrivateKey" > "$sshPrivateKeyFile"
  chmod 0700 "$sshPrivateKeyFile"
  sshOpts+=( -o "IdentityFile=${sshPrivateKeyFile}" )
fi

### Functions ###

log() {
  echo "--- $*" >&2
}

copyToTarget() {
  NIX_SSHOPTS="${sshOpts[*]}" nix-copy-closure --to "$targetHost" "$@"
}

# assumes that passwordless sudo is enabled on the server
targetHostCmd() {
  shouldEscalate="${1}"
  shift 1

  # ${*@Q} escapes the arguments losslessly into space-separted quoted strings.
  # `ssh` did not properly maintain the array nature of the command line,
  # erroneously splitting arguments with internal spaces, even when using `--`.
  # Tested with OpenSSH_7.9p1.
  #
  # shellcheck disable=SC2029
#   ssh "${sshOpts[@]}" "$targetHost" "./maybe-sudo.sh ${*@Q}"
 # TODO: fixup
 # TODO: provide option for no ssh
 # TODO: provide option for no sudo
  if [[ "${shouldEscalate:-false}" == "true" ]]; then
    local script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    commandToRun="${script_path}/./maybe-sudo.sh ${*@Q}"
  else
    commandToRun="${*@Q}"
  fi

  if [[ "${verboseOutput:-false}" == "true" ]]; then
    log "executing command (local deploy is ${localDeploy}): ${commandToRun}"
  fi

  if [[ "${localDeploy:-false}" == "true" ]]; then
    sh -c "${commandToRun}"
  else
    ssh "${sshOpts[@]}" "$targetHost" "${commandToRun}"
  fi
}

# Setup a temporary ControlPath for this session. This speeds-up the
# operations by not re-creating SSH sessions between each command. At the end
# of the run, the session is forcefully terminated.
setupControlPath() {
  sshOpts+=(
    -o "ControlPath=$workDir/ssh_control"
  )
  cleanupControlPath() {
    local ret=$?
    # Avoid failing during the shutdown
    set +e
    # Close ssh multiplex-master process gracefully
    log "closing persistent ssh-connection"
    ssh "${sshOpts[@]}" -O stop "$targetHost"
    rm -rf "$workDir"
    exit "$ret"
  }
  trap cleanupControlPath EXIT
}

### Main ###

if [[ "${localDeploy:-false}" != "true" ]]; then
  setupControlPath
fi

if [[ "${buildOnTarget:-false}" == "true" ]]; then

  # Upload derivation
  log "uploading derivations"
  copyToTarget "$drvPath" --gzip --use-substitutes

  # Build remotely
  log "building on target"
  if [[ "${verboseOutput:-false}" == "true" ]]; then
    set -x
  fi

  # assume never need  to elevate to realise
  targetHostCmd "false" "nix-store" "--realize" "$drvPath" "${buildArgs[@]}"

else

  # Build derivation
  log "building on deployer"
  outPath=$(nix-store --realize "$drvPath" "${buildArgs[@]}")

  # Upload build results
  if [[ "${localDeploy:-false}" != "true" ]]; then
    log "uploading build results"
    copyToTarget "$outPath" --gzip --use-substitutes
  fi
fi

# Activate
log "activating configuration"
targetHostCmd "${escalateDeployForProfile}" nix-env --profile "$profile" --set "$outPath"
if [[ "${activateActions:--}" == "-" ]]; then
  targetHostCmd "${escalateDeployForCommands}" "${outPath}/${activateScriptPath}"
else
  # read actions as space separated array
  IFS=' ' read -ra activateActionArray <<< "${activateActions}"
  targetHostCmd "${escalateDeployForCommands}" "${outPath}/${activateScriptPath}" "${activateActionArray[@]}"
fi

# Cleanup previous generations
log "collecting old nix derivations"
# Deliberately not quoting $deleteOlderThan so the user can configure something like "1 2 3"
# to keep generations with those numbers
# targetHostCmd "nix-env" "--profile" "$profile" "--delete-generations" $deleteOlderThan
targetHostCmd "${escalateDeployForGC}" "nix-env" "--profile" "$profile" "--delete-generations" $deleteOlderThan
targetHostCmd "${escalateDeployForCommands}" "nix-store" "--gc"
