# SELinux {#module-security-selinux}

The `security.selinux` module runs NixOS with SELinux: it loads a policy at boot, labels the Nix store and the rest of the filesystem, and keeps both in step with the system generation. Nix itself is not changed.

The module is experimental.

## Enabling {#module-security-selinux-enabling}

Start in permissive mode. Nothing is blocked; what would be blocked is logged.

```nix
{
  security.selinux = {
    enable = true;
    type = "refpolicy";
    mode = "permissive";
  };
}
```

Rebuild and reboot. The first boot labels the whole Nix store, which takes time in proportion to the number of files in it. Later boots only label store paths that are new.

Check the result:

```ShellSession
$ sestatus
$ ps -eZ | head
$ journalctl -b | grep 'avc:  denied'
```

When a normal session of work produces no denials, switch to `mode = "enforcing"`.

## Policy types {#module-security-selinux-policy-types}

| `type` | What it is | Use it for |
|---|---|---|
| `minimal` (default) | A small policy written for NixOS. Everything is unconfined except domains you add as CIL modules. | Trying the mechanism, or confining a few services of your own. |
| `refpolicy` | The SELinux reference policy with a NixOS module. | Running system services in the domains the reference policy has for them. Experimental. |

## What is confined {#module-security-selinux-confined}

With `refpolicy`, these run in the reference policy's domains without further configuration: systemd's helper daemons (journald, udev, logind and others), D-Bus, and, through `security.selinux.confine`:

| Option | Default | Effect |
|---|---|---|
| `confine.sshd` | on | The OpenSSH daemon runs in `sshd_t`. |
| `confine.nscd` | on | The name service cache daemon runs in `nscd_t`. |
| `confine.getty` | on | The console login prompt runs in `getty_t` and the login program in `local_login_t`. |
| `confine.dhcpcd` | on | The DHCP client runs in `dhcpc_t`. |
| `confine.nix` | on | The Nix daemon runs in `nix_daemon_t`, which is not restricted. |
| `confine.nixBuilds` | off | Builders started by the Nix daemon run in `nix_build_t`. See below. |

Every other service runs unconfined, as with a targeted policy on other distributions. Users log in unconfined by default; `security.selinux.loginMappings` maps login names to SELinux users.

### Confined builds {#module-security-selinux-confined-builds}

With `confine.nixBuilds = true` a build may write only its outputs and its build directory, may not read the password database, and may not signal or trace processes outside the build. This is in addition to the Nix sandbox.

Every program the daemon starts enters this domain. A `post-build-hook` and the `ssh` client used for remote builders therefore run confined and will lack access they need. Leave the option off if you use either. Builds with the sandbox disabled are not supported with it.

## Labels in the Nix store {#module-security-selinux-store-labels}

The store is labelled by rules that match path patterns: programs get `bin_t`, libraries `lib_t`, and so on. These types carry no privilege, because any user can build a store path that matches a pattern.

A type that carries privilege, such as the entry point of a domain, is given only to an exact store path:

```nix
{
  security.selinux.entrypoints.myservice = {
    path = "${pkgs.myservice}/bin/myserviced";
    type = "myservice_exec_t";
  };
}
```

`security.selinux.fhsLabelledPackages` does this in bulk: each program in the listed packages gets the type the reference policy gives the same file under `/usr`.

`security.selinux.fileContexts` adds pattern rules for paths outside the store. Do not use it to give store content a privileged type.

A path built or downloaded after boot has the generic store type until the next boot, switch or run of `/run/current-system/selinux-setup`. Unconfined users can run it in the meantime.

## Adding policy {#module-security-selinux-adding-policy}

With `minimal`, add CIL fragments. A fragment that does not compile fails the system build and the error names it.

```nix
{
  security.selinux.modules.myservice.cil = ''
    (type myservice_t)
    (roletype system_r myservice_t)
  '';
}
```

With `refpolicy`, write the module in the reference policy's language and name the service's program by exact path:

```nix
{
  security.selinux = {
    modules.myservice.te = ''
      type myservice_t;
      type myservice_exec_t;
      init_daemon_domain(myservice_t, myservice_exec_t)
      logging_send_syslog_msg(myservice_t)
    '';
    entrypoints.myservice = {
      path = "''${pkgs.myservice}/bin/myserviced";
      type = "myservice_exec_t";
    };
  };
}
```

systemd then starts the service in `myservice_t`, where it may do only what the module allows. Booleans and tunables are set with `security.selinux.booleans`.

The policy is part of the system closure. There is no mutable policy store: `semodule` and `setsebool -P` have nothing to write to. A change to the policy is a change to the configuration, and it switches and rolls back with the system generation. A switch is refused before anything is activated when the new policy's format version is newer than the running kernel accepts; set {option}`security.selinux.policyVersion`, or activate the generation with `boot` and reboot into its kernel.

## Finding out what is denied {#module-security-selinux-denials}

```ShellSession
$ journalctl -b | grep 'avc:  denied'
```

This shows denials from the kernel and from systemd, which checks some requests itself. The reference policy hides denials it expects (`dontaudit` rules). If something fails with "Permission denied" and nothing is logged, build once with `security.selinux.logAllDenials = true`, in permissive mode, and look again.

`security.selinux.developmentTools = true` installs `sesearch`, `audit2allow` and related tools.

## Store optimisation {#module-security-selinux-store-optimisation}

`nix-store --optimise` links identical files in different store paths to one inode, and one inode has one label. A program with a specific type can lose it this way. The module restores such labels at boot, at switch, and after the scheduled optimisation (`nix.optimise.automatic`). After running the optimiser by hand, run:

```ShellSession
# /run/current-system/selinux-setup
```

Do not use `nix.settings.auto-optimise-store` with SELinux; the module warns about it. Confined services name their domain in their unit, so a service whose program has lost its label fails to start instead of running unconfined.

## Recovery {#module-security-selinux-recovery}

If an enforcing system does not boot or cannot be logged in to:

1. **Boot the previous generation** from the boot loader menu. Its policy and mode are those of that generation.
2. **Boot permissive once.** Edit the boot entry and add `enforcing=0` to the kernel command line. The policy is loaded and denials are logged, but nothing is blocked.
3. **Boot without SELinux.** Remove `selinux` from the `lsm=` kernel parameter in the boot entry. Files created during such a boot are unlabelled; the next boot with SELinux relabels the paths in `security.selinux.relabelPaths` only when the rules changed, so run `restorecon -RF` on what you touched, or boot permissive first.

In enforcing mode the system refuses to boot if the policy cannot be loaded or the store cannot be labelled, instead of continuing unprotected. Options 2 and 3 get past that.

Options 2 and 3 are covered by the `selinux-recovery` test. A `nixos-rebuild switch` during a permissive rescue boot applies the configured mode again, so the system becomes enforcing at that point if the configuration says so.

## Limits {#module-security-selinux-limits}

- Not compatible with `security.apparmor.enable` or `system.nixos-init.enable` in this version.
- Not yet tried on a real machine.
