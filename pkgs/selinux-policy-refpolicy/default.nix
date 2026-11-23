# The SELinux reference policy built as one monolithic binary policy, in
# the layout of /etc/selinux/<name>, with a NixOS module added.
{
  lib,
  selinux-refpolicy,
  policycoreutils,
  libselinux,
  name ? "refpolicy",
  policyVersion ? 33,
  extraFileContexts ? "",
  # Packages whose programs get the types the reference policy gives the
  # same programs at their usual FHS locations.
  fhsPackages ? [ ],
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
    # For each program in fhsPackages, ask the policy what type it gives
    # the same file under /usr. Where that is more specific than the
    # generic type the store rules give, write a rule for the exact
    # store path. The hash in the path cannot be chosen by whoever
    # builds another package, so these types cannot be forged.
    mkdir -p $out/nixos
    : > $out/nixos/exact-paths
    lookup() {
      ${lib.getExe' libselinux "selabel_lookup"} -b file \
        -f $out/contexts/files/file_contexts -k "$1" -t file 2>/dev/null \
        | sed -n 's/^Default context: //p'
    }
    for package in ${lib.escapeShellArgs (map toString fhsPackages)}; do
      for dir in bin sbin libexec lib/systemd lib/udev; do
        [ -d "$package/$dir" ] || continue
        find "$package/$dir" -type f -perm -0100 ! -name '*.so*' -print
      done
    done | sort -u > fhs-candidates
    : > fhs-rules
    while IFS= read -r file; do
      relative=''${file#/nix/store/*/}
      wanted=$(lookup "/usr/$relative")
      generic=$(lookup "$file")
      if [ -n "$wanted" ] && [ "$wanted" != "<<none>>" ] && [ "$wanted" != "$generic" ]; then
        printf '%s\t--\t%s\n' "$(printf '%s' "$file" | sed 's/[][\.*+?(){}|^$]/\\&/g')" "$wanted" >> fhs-rules
        echo "$file" >> $out/nixos/exact-paths
      fi
    done < fhs-candidates
    echo "FHS-derived rules: $(wc -l < fhs-rules)"
    cat fhs-rules
    cat fhs-rules >> $out/contexts/files/file_contexts
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
