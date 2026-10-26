# 100-windows-baseline -- THE CONTROL: it installs nothing and asserts nothing is found.
#
# A suite that only asserts must_find cannot tell a working matcher from one that claims
# everything. GitHub's Windows image is far from empty -- Visual Studio, Docker, Rust and
# .NET toolchains, Edge, Chrome and Windows' own MSIX packages -- so this is where an
# over-broad Windows route would fail first.
exit 0
