# Composes the policy for this system and exposes it under /etc/selinux.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.security.selinux;

  secilc = pkgs.secilc or (pkgs.callPackage ../../../../pkgs/secilc { });

  # Rules that name one exact store path. The hash in the path cannot be
  # chosen by whoever builds a package, so only content the system
  # configuration designates can receive these types.
  exactRules = lib.concatStrings (
    lib.unique (
      map (e: "${lib.escapeRegex (toString e.path)}\t--\tsystem_u:object_r:${e.type}:s0\n") (
        lib.attrValues cfg.entrypoints
      )
    )
  );

  genericFileContexts =
    (
      if cfg.type == "refpolicy" then
        pkgs.selinux-refpolicy.version
        + builtins.readFile ../../../../pkgs/selinux-policy-refpolicy/nixos.fc
      else
        builtins.readFile ../../../../policy/minimal/file_contexts
    )
    + cfg.fileContexts;
in
{
  options.security.selinux = {
    policy = lib.mkOption {
      type = lib.types.package;
      description = ''
        The built policy: a directory with the layout of
        {file}`/etc/selinux/<type>`. The default is the minimal policy
        extended with {option}`security.selinux.modules`,
        {option}`security.selinux.fileContexts` and
        {option}`security.selinux.entrypoints`.
      '';
      defaultText = lib.literalMD "the minimal policy built from this configuration";
    };

    modules = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.cil = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Policy rules in CIL.";
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          myservice.cil = '''
            (type myservice_t)
            (roletype system_r myservice_t)
          ''';
        }
      '';
      description = ''
        Policy fragments compiled into the system policy. A fragment that
        does not compile fails the system build, and the error names it.
      '';
    };

    fileContexts = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        /srv/www(/.*)?	system_u:object_r:usr_t:s0
      '';
      description = ''
        Extra file context rules. Rules for the Nix store written here
        match on path patterns that any local user can imitate, so they
        must not hand out types that carry privilege. Use
        {option}`security.selinux.entrypoints` for that.
      '';
    };

    entrypoints = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.path;
              description = "Exact path of a regular file in the Nix store.";
            };
            type = lib.mkOption {
              type = lib.types.str;
              description = "SELinux type to label that file with.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          nginx = {
            path = "''${pkgs.nginx}/bin/nginx";
            type = "nginx_exec_t";
          };
        }
      '';
      description = ''
        Files in the Nix store that get a specific type, named by their
        exact store path. This is the only way store content receives a
        type that carries privilege, such as the entry point of a domain.
      '';
    };

    fhsLabelledPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = lib.optional (cfg.type == "refpolicy") config.systemd.package;
      defaultText = lib.literalExpression ''
        lib.optional (config.security.selinux.type == "refpolicy") config.systemd.package
      '';
      description = ''
        Packages whose programs get the types the reference policy gives
        the same programs at their usual locations under {file}`/usr`.
        Each one is named by its exact store path, so the service it
        belongs to enters the domain the policy has for it. Used by the
        `refpolicy` policy type.
      '';
    };

    labelRevision = lib.mkOption {
      type = lib.types.str;
      internal = true;
      description = ''
        Identifies the generic labelling rules. Store paths labelled under
        one revision are not visited again until it changes.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    security.selinux = {
      policy = lib.mkDefault (
        if cfg.type == "refpolicy" then
          assert lib.assertMsg (cfg.modules == { }) ''
            security.selinux.modules is not supported with the refpolicy
            policy type yet.
          '';
          pkgs.callPackage ../../../../pkgs/selinux-policy-refpolicy {
            name = cfg.type;
            policyVersion = if cfg.policyVersion != null then cfg.policyVersion else 33;
            extraFileContexts = cfg.fileContexts + exactRules;
            fhsPackages = cfg.fhsLabelledPackages;
            seusers = lib.concatStrings (
              lib.mapAttrsToList (login: m: "${login}:${m.user}:${m.range}\n") cfg.loginMappings
            );
          }
        else
          pkgs.callPackage ../../../../pkgs/selinux-policy-minimal {
            inherit secilc;
            name = cfg.type;
            policyVersion = if cfg.policyVersion != null then cfg.policyVersion else 33;
            extraCil = lib.mapAttrsToList (name: module: pkgs.writeText "${name}.cil" module.cil) cfg.modules;
            extraFileContexts = cfg.fileContexts + exactRules;
          }
      );

      labelRevision = builtins.substring 0 32 (builtins.hashString "sha256" genericFileContexts);

      # PID 1 enters its domain only if the systemd binary carries this type.
      entrypoints = {
        systemd = {
          path = "${config.systemd.package}/lib/systemd/systemd";
          type = "init_exec_t";
        };
        systemd-initrd = {
          path = "${config.boot.initrd.systemd.package}/lib/systemd/systemd";
          type = "init_exec_t";
        };
      };
    };

    environment.etc."selinux/${cfg.type}".source = cfg.policy;
  };
}
