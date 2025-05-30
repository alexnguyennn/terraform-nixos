variable "target_host" {
  type        = string
  description = "DNS host to deploy to"
}

variable "target_user" {
  type        = string
  description = "SSH user used to connect to the target_host"
  default     = "root"
}

variable "target_port" {
  type        = number
  description = "SSH port used to connect to the target_host"
  default     = 22
}

variable "ssh_private_key" {
  type        = string
  description = "Content of private key used to connect to the target_host"
  default     = ""
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to private key used to connect to the target_host"
  default     = ""
}

variable "ssh_agent" {
  type        = bool
  description = "Whether to use an SSH agent. True if not ssh_private_key is passed"
  default     = null
}

variable "extra_eval_args" {
  type        = list(string)
  description = "List of arguments to pass to the nix evaluation"
  default     = []
}

variable "extra_build_args" {
  type        = list(string)
  description = "List of arguments to pass to the nix builder"
  default     = []
}

variable "build_on_target" {
  type        = string
  description = "Avoid building on the deployer. Must be true or false. Has no effect when deploying from an incompatible system. Unlike remote builders, this does not require the deploying user to be trusted by its host."
  default     = false
}

variable "triggers" {
  type        = map(string)
  description = "Triggers for deploy"
  default     = {}
}

variable "keys" {
  type        = map(string)
  description = "A map of filename to content to upload as secrets in /var/keys"
  default     = {}
}

variable "target_system" {
  type        = string
  description = "Nix system string"
  default     = "x86_64-linux"
}

variable "delete_older_than" {
  type        = string
  description = "Can be a list of generation numbers, the special value old to delete all non-current generations, a value such as 30d to delete all generations older than the specified number of days (except for the generation that was active at that point in time), or a value such as +5 to keep the last 5 generations ignoring any newer than current, e.g., if 30 is the current generation +5 will delete generation 25 and all older generations."
  default     = "+1"
}

variable "flake_dir" {
  type        = string
  description = "path to directory containing the nix flake to diff and deploy"
}

variable "flake_attr" {
  type        = string
  description = "flake path (after # in nix build .#path.To.Flake) to evaluate and deploy"
}

variable "activate_script_path" {
  type        = string
  description = "path relative to store output path of activation script. Defaults to NixOS value"
  default     = "bin/switch-to-configuration"
}

variable "activate_actions" {
  type        = string # taken as string but will be interpreted as individual arguments in script
  description = "space separated action arguments to give to activation script. Defaults to value for NixOS switch-to-configuration"
  default     = "switch"
}

variable "nix_profile" {
  type        = string
  description = "path relative to /nix/var/nix/profiles/ (default profile location) for profile to use. Defaults to value for NixOS, modify for home-manager for example."
  default     = "system"
}

variable "verbose_output" {
  type        = bool
  description = "enable verbose output for debugging"
  default     = false
}

variable "escalate_deploy" {
  type        = map(bool)
  description = "use maybe_sudo to escalate before running activation script (useful for NixOS but not necessary for Home Manager)"
  default = {
    profile            = false # used in nix profile setting
    commands           = false
    garbage_collection = false
  }
}

variable "garbage_collection" {
  type = bool
  # turns on garbage collection at the end
  default = true
}

variable "local_deploy" {
  type        = bool
  description = "run in local mode: bypasses ssh for remote deployment and just runs a nix-flake-deploy locally"
  default     = false
}

# --------------------------------------------------------------------------

locals {
  triggers = {
    deploy_nixos_drv      = data.external.nixos-instantiate.result["drv_path"]
    deploy_nixos_keys     = sha256(jsonencode(var.keys))
    deploy_nix_references = data.external.nixos-instantiate.result["references"]
  }

  extra_build_args     = var.extra_build_args
  ssh_private_key_file = var.ssh_private_key_file == "" ? "-" : var.ssh_private_key_file
  ssh_private_key      = local.ssh_private_key_file == "-" ? var.ssh_private_key : file(local.ssh_private_key_file)
  ssh_agent            = var.ssh_agent == null ? (local.ssh_private_key != "") : var.ssh_agent
  build_on_target      = data.external.nixos-instantiate.result["currentSystem"] != var.target_system ? true : tobool(var.build_on_target)
  out_path             = data.external.nixos-instantiate.result["out_path"]
}

# used to detect changes in the configuration
data "external" "nixos-instantiate" {
  program = concat([
    "${path.module}/nix-eval.sh",
    var.flake_dir,
    var.flake_attr
    # end of positional arguments
    ],
    var.extra_eval_args,
  )
}

resource "null_resource" "deploy_nixos" {
  // TODO: make count work - abstract output to take whichever one is instantiated
  count    = var.local_deploy ? 0 : 1
  triggers = merge(var.triggers, local.triggers)

  connection {
    type        = "ssh"
    host        = var.target_host
    port        = var.target_port
    user        = var.target_user
    agent       = local.ssh_agent
    timeout     = "100s"
    private_key = local.ssh_private_key == "-" ? "" : local.ssh_private_key
  }

  # copy the secret keys to the host
  provisioner "file" {
    content     = jsonencode(var.keys)
    destination = "packed-keys.json"
  }

  # FIXME: move this to nixos-deploy.sh
  provisioner "file" {
    source      = "${path.module}/unpack-keys.sh"
    destination = "unpack-keys.sh"
  }

  # FIXME: move this to nixos-deploy.sh
  provisioner "file" {
    source      = "${path.module}/maybe-sudo.sh"
    destination = "maybe-sudo.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x unpack-keys.sh maybe-sudo.sh",
      "./maybe-sudo.sh ./unpack-keys.sh ./packed-keys.json",
    ]
  }

  # do the actual deployment
  provisioner "local-exec" {
    interpreter = concat([
      "${path.module}/nix-flake-deploy.sh",
      data.external.nixos-instantiate.result["drv_path"],
      data.external.nixos-instantiate.result["out_path"],
      var.local_deploy,
      "${var.target_user}@${var.target_host}",
      var.target_port,
      local.ssh_private_key == "" ? "-" : local.ssh_private_key,
      var.verbose_output,
      var.activate_actions == "" ? "-" : var.activate_actions,
      var.activate_script_path,
      local.build_on_target,
      var.nix_profile,
      var.escalate_deploy.profile,
      var.escalate_deploy.commands,
      var.escalate_deploy.garbage_collection,
      var.delete_older_than,
      var.garbage_collection,
      ],
      local.extra_build_args
    )
    command = "ignoreme"
  }
}

resource "null_resource" "deploy_nixos_local" {
  count    = var.local_deploy ? 1 : 0
  triggers = merge(var.triggers, local.triggers)

  # do the actual deployment
  provisioner "local-exec" {
    interpreter = concat([
      "${path.module}/nix-flake-deploy.sh",
      data.external.nixos-instantiate.result["drv_path"],
      data.external.nixos-instantiate.result["out_path"],
      var.local_deploy,
      "${var.target_user}@${var.target_host}",
      var.target_port,
      local.ssh_private_key == "" ? "-" : local.ssh_private_key,
      var.verbose_output,
      var.activate_actions == "" ? "-" : var.activate_actions,
      var.activate_script_path,
      local.build_on_target,
      var.nix_profile,
      var.escalate_deploy.profile,
      var.escalate_deploy.commands,
      var.escalate_deploy.garbage_collection,
      var.delete_older_than,
      var.garbage_collection,
      ],
      local.extra_build_args
    )
    command = "ignoreme"
  }
}

# --------------------------------------------------------------------------

output "id" {
  description = "random ID that changes on every nixos deployment"
  //  value       = null_resource.deploy_nixos.id
  value = var.local_deploy ? null_resource.deploy_nixos_local[0].id : null_resource.deploy_nixos[0].id
}
