# deploy_nix_config

A Terraform module that knows how to deploy Nixs Flakes onto a target host, based on [deploy_nixos](../deploy_nixos/README.md)

This allows you to describe an infrastructure as code with Terraform and delegate
the machine configuration with NixOS. All directed by Terraform.

The advantage of this method is that if any of the Nix code changes, the
difference will be detected on the next "terraform plan".

This module also introduces `nix-eval.sh` and `nix-flake-deploy.sh` in place of `nix-instantiate.sh` and `nixos-deploy.sh` used in the `deploy_nixos` module. This uses and requires  more variable arguments in comparison but is made to be more generic and compatible with flake paths.

## TODO
* [ ] fixup maybe sudo (add bld group to root or specify user to run as via dedicated variable)
* [ ] enable wsl compatibility (remote into windows openssh; add wsl commands prior to activating)

## Usage

Specify `flake_dir` path to your flake, `flake_attr` the flake attribute you want to deploy and a way to activate the built derivation via `activate_script_path` and `activate_action`. You can also specify the `nix_profile` to change. Default values should mostly match those used for deploying a NixOS configuration, it just needs a `flake_attr` that points to an OS flake.

### Secret handling

Keys can be passed to the "keys" attribute. Each key will be installed under
`/var/keys/${key}` with the content as the value.

For services to access one of the keys, add the service user to the "keys"
group.

The target machine needs `jq` installed prior to the deployment (as part of
the base image). If `jq` is not found it will try to use a version from
`<nixpkgs>`.

### Disabling sandboxing

Unfortunately some time it's required to disable the nix sandboxing. To do so,
add `["--option", "sandbox", "false"]` to the "extra_build_args" parameter.

If that doesn't work, make sure that your user is part of the nix
"trusted-users" list.

### Non-root `target_user`

It is possible to connect to the target host using a user that is not `root`
under certain conditions:

* sudo needs to be installed on the machine
* the user needs password-less sudo access on the machine

This would typically be provisioned in the base image.

### Binary cache configuration

One thing that might be surprising is that the binary caches (aka
substituters) are taken from the machine configuration. This implies that the
user Nix configuration will be ignored in that regard.

## Dependencies

* `bash` 4.0+
* `nix`
* `openssh`
* `jq`

## Known limitations

The deployment machine requires Nix with access to a remote builder with the
same system as the target machine.

Because Nix code is being evaluated at "terraform plan" time, deploying a lot
of machine in the same target will require a lot of RAM.

All the secrets share the same "keys" group.

When deploying as non-root, it assumes that passwordless `sudo` is available.

The target host must already have NixOS installed.

### config including computed values

The module doesn't work when `<computed>` values from other resources are
interpolated with the "config" attribute. Because it happens at evaluation
time, terraform will render an empty drvPath.

see also:
* https://github.com/hashicorp/terraform/issues/16380
* https://github.com/hashicorp/terraform/issues/16762
* https://github.com/hashicorp/terraform/issues/17034

<!-- terraform-docs-start -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 0.12 |

## Providers

| Name | Version |
|------|---------|
| external | n/a |
| null | n/a |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| flake_dir | path to directory containing a `flake.nix` | `string` | n/a | yes |
| flake_attr | flake path (after # in nix build .#path.To.Flake) to evaluate and deploy | `string` | n/a | yes |
| cache_flake_attr | flake path (after # in nix build .#path.To.Flake) to get binary cache details from (nixosSystem flakes will have this; variables live in `nixpkgs`) | `string` | n/a | yes |
| activate_script_path | path relative to store output path of activation script. Defaults to NixOS value| `string` | `"bin/switch-to-configuration"` | no |
| activate_action | action argument to give to activation script. Defaults to value for NixOS switch-to-configuration | `string` | `"switch"` | no |
| nix_profile | path relative to /nix/var/nix/profiles/ (default profile location) for profile to use. Defaults to value for NixOS, modify for home-manager for example. | `string` | `"system"` | no |
| build\_on\_target | Avoid building on the deployer. Must be true or false. Has no effect when deploying from an incompatible system. Unlike remote builders, this does not require the deploying user to be trusted by its host. | `string` | `false` | no |
| extra\_build\_args | List of arguments to pass to the nix builder | `list(string)` | `[]` | no |
| extra\_eval\_args | List of arguments to pass to the nix evaluation | `list(string)` | `[]` | no |
| keys | A map of filename to content to upload as secrets in /var/keys | `map(string)` | `{}` | no |
| ssh\_agent | Whether to use an SSH agent. True if not ssh\_private\_key is passed | `bool` | `null` | no |
| ssh\_private\_key | Content of private key used to connect to the target\_host | `string` | `""` | no |
| ssh\_private\_key\_file | Path to private key used to connect to the target\_host | `string` | `""` | no |
| target\_host | DNS host to deploy to | `string` | n/a | yes |
| target\_port | SSH port used to connect to the target\_host | `number` | `22` | no |
| target\_system | Nix system string | `string` | `"x86_64-linux"` | no |
| target\_user | SSH user used to connect to the target\_host | `string` | `"root"` | no |
| triggers | Triggers for deploy | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| id | random ID that changes on every nixos deployment |

<!-- terraform-docs-end -->
