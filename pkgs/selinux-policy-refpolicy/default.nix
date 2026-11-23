# The SELinux reference policy built as one monolithic binary policy, in
# the layout of /etc/selinux/<name>, with a NixOS module added.
{
  lib,
  selinux-refpolicy,
  policycoreutils,
  name ? "refpolicy",
  policyVersion ? 33,
  extraFileContexts ? "",
  # Contents of the seusers file; null keeps the reference policy's own.
  seusers ? null,
}:
(selinux-refpolicy.override { inherit policyVersion; }).overrideAttrs (old: {
  pname = "selinux-policy-${name}";

  postPatch = (old.postPatch or "") + ''
    mkdir -p policy/modules/nixos
    cp ${./nixos.te} policy/modules/nixos/nixos.te
    cp ${./nixos.fc} policy/modules/nixos/nixos.fc
    cp ${./nixos.if} policy/modules/nixos/nixos.if
    echo '<summary>NixOS-specific policy.</summary>' > policy/modules/nixos/metadata.xml
  '';

  makeFlags = old.makeFlags ++ [
    "MONOLITHIC=y"
    "NAME=${name}"
    "TYPE=mcs"
    "UNK_PERMS=allow"
    # No separation between SELinux users beyond what types give, as in
    # other targeted-style distributions.
    "UBAC=n"
    "SETFILES=${lib.getExe' policycoreutils "setfiles"}"
  ];

  installTargets = "install";

  inherit extraFileContexts;
  passAsFile = [ "extraFileContexts" ];

  # Flatten to the layout the NixOS module expects, and append the rules
  # the system configuration adds. Later rules win over earlier ones.
  postInstall = ''
    mv $out/etc/selinux/${name}/* $out/
    rm -r $out/etc
    # Home directory rules are generated from the accounts in the build
    # sandbox, where root's home is /build.
    sed -i -E 's|^/build([/[:space:]])|/root\1|' $out/contexts/files/file_contexts.homedirs
    cat "$extraFileContextsPath" >> $out/contexts/files/file_contexts
    ${lib.optionalString (seusers != null) ''
      cat ${builtins.toFile "seusers" seusers} > $out/seusers
    ''}
    ${lib.getExe' policycoreutils "setfiles"} -c $out/policy/policy.${toString policyVersion} \
      $out/contexts/files/file_contexts
  '';

  passthru = (old.passthru or { }) // {
    inherit policyVersion;
    policyName = name;
  };
})
