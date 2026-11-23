# Contract: NixOS configuration options

> Written before the implementation and kept as a record. The options as built are described in the [manual chapter](../../../nixos/modules/security/selinux/selinux.md) and in the module itself.

This is the interface administrators and service module authors use. Names follow the open upstream draft where it already defines them (`enable`, `mode`, `type`, `policyVersion`), so a later merge is not a rename.

## Administrator options

| Option | Type | Default | Meaning | Milestone |
|---|---|---|---|---|
| `security.selinux.enable` | bool | `false` | Turns the feature on. When false, nothing else in this module has any effect. | M1 |
| `security.selinux.mode` | `"permissive"` or `"enforcing"` | `"permissive"` | Enforcement mode at boot. | M1 |
| `security.selinux.type` | string | `"minimal"` in M1, `"nixos"` from M2 | Policy name, used as `SELINUXTYPE`. | M1 |
| `security.selinux.policy` | package | derived from `type` | The built policy tree. Override to supply a custom policy. | M1 |
| `security.selinux.policyVersion` | null or int | null (taken from the kernel) | Kernel policy format version to build. | M1 |
| `security.selinux.booleans` | attrs of bool | `{}` | Policy tunables, fixed at build time. | M3 |
| `security.selinux.logins` | attrs of string | `{ __default__ = "unconfined_u"; }` | Maps system users to SELinux users. | M2 |
| `security.selinux.fileContexts` | lines | `""` | Extra labelling rules for mutable paths. | M2 |
| `security.selinux.relabelPaths` | list of path | `[ "/etc" "/var" "/root" "/home" ]` | Mutable paths relabelled when the policy changes. | M1 |
| `security.selinux.developmentTools` | bool | `false` | Installs analysis tools and enables the audit daemon. | M1 |

## Service module options

| Option | Type | Meaning | Milestone |
|---|---|---|---|
| `security.selinux.modules.<name>.cil` | lines | Policy fragment in CIL. | M3 |
| `security.selinux.modules.<name>.te`, `.if`, `.fc` | lines | Policy fragment in refpolicy source form. | M3 |
| `security.selinux.entrypoints.<name>` | `{ path; type; }` | Designates one exact store path as an entry point of the given type. The only way a store path gets a privileged label. | M2 |
| `systemd.services.<name>.serviceConfig.SELinuxContext` | string | Existing systemd setting. Selects the service's domain. | M2 |

## Guarantees

- With `enable = false`, the system closure is identical to one built without the module.
- Enabling both this module and `security.apparmor.enable` fails evaluation with a message naming both options.
- An invalid policy fragment fails the system build and names the fragment.
- `mode = "enforcing"` with a policy that cannot load refuses the switch before services change.
- A path gets a privileged type only through `entrypoints` or the module's own built-in list (systemd, unit files, the `etc` tree).

## Outputs on the running system

- `/etc/selinux/config` and `/etc/selinux/<type>/` (policy, contexts, file contexts, login mappings), all from the system closure.
- `/var/lib/selinux-nixos/labelled`: record of which store paths are labelled under which rule set.
- Denial records in the kernel log and journal, and in the audit log when the audit daemon is enabled.
