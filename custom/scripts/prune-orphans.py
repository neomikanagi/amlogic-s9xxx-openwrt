#!/usr/bin/env python3
"""Find the packages that were only there because of packages the fragment disabled.

    prune-orphans.py <.config before the fragment> <tmp/.packageinfo> <fragment>

The first argument must be the defconfig'ed .config of the UNMODIFIED upstream config: it is
the only place that still shows which package needed which.

Prints one package name per line (the orphans) on stdout, a human readable report on
stderr. A package is an orphan when it was selected, something selected depended on it (so
it was an "attached" package, not a user choice), and every one of those users is a disabled
package or an orphan itself. `#!keep <pkg>` lines in the fragment protect a package. Only
package symbols are handled; kconfig re-selects anything that is still needed.
"""
import re
import sys

config_path, info_path, fragment_path = sys.argv[1:4]

config = open(config_path).read()
selected = set(re.findall(r"^CONFIG_PACKAGE_([^=\s]+)=[ym]$", config, re.M))

fragment = open(fragment_path).read()
disabled = set(re.findall(r"^# CONFIG_PACKAGE_([^\s]+) is not set$", fragment, re.M))
keep = set(re.findall(r"^#!keep\s+(\S+)", fragment, re.M))

# --- package metadata -------------------------------------------------------------
deps = {}  # package -> set(names it depends on)
provides = {}  # alias -> set(packages providing it)
for block in open(info_path, errors="replace").read().split("\n\n"):
    m = re.search(r"^Package: (\S+)$", block, re.M)
    if not m:
        continue
    name = m.group(1)
    d = re.search(r"^Depends: (.*)$", block, re.M)
    ds = set()
    if d:
        for tok in d.group(1).split():
            tok = tok.lstrip("+")
            if ":" in tok:  # CONFIG_FOO:pkg  (dependency only if FOO is set)
                tok = tok.split(":")[-1]
            if not tok or tok[0] in "@!" or any(c in tok for c in "()&|"):
                continue
            ds.add(tok.split("@")[0])
    deps.setdefault(name, set()).update(ds)
    p = re.search(r"^Provides: (.*)$", block, re.M)
    if p:
        for alias in p.group(1).split():
            provides.setdefault(alias.lstrip("@"), set()).add(name)


def resolve(dep):
    """names of the selected packages that satisfy dependency `dep`"""
    out = set()
    if dep in selected:
        out.add(dep)
    for prov in provides.get(dep, ()):
        if prov in selected:
            out.add(prov)
    return out


users = {p: set() for p in selected}  # package -> selected packages that depend on it
for p in selected:
    for dep in deps.get(p, ()):
        for target in resolve(dep):
            if target != p:
                users[target].add(p)

gone = {p for p in disabled}
orphans = set()
changed = True
while changed:
    changed = False
    for p in sorted(selected - gone):
        if p in keep or not users[p]:
            continue  # user choice (nobody depends on it) or protected
        if users[p] <= gone:
            gone.add(p)
            orphans.add(p)
            changed = True

sys.stderr.write("disabled by the fragment : %d (%d of them were selected)\n" % (len(disabled), len(disabled & selected)))
sys.stderr.write("attached packages dropped : %d\n" % len(orphans))
for p in sorted(orphans):
    sys.stderr.write("   - %s  (was needed by: %s)\n" % (p, ", ".join(sorted(users[p]))))
for p in sorted(orphans):
    print(p)
