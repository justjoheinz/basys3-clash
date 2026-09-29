# Native openXC7 toolchain image: yosys + nextpnr-xilinx + prjxray.
#
#   make openxc7-image    # build it (slow, one-off)
#   make bitstream        # use it
#
# Podman builds this for the host's own CPU, so on Apple Silicon it is a genuine
# arm64 image: no Rosetta, no qemu, no x86 anywhere in that flow.
#
# Nothing below pins an architecture -- the base image is a multi-arch manifest and
# the Nix expressions ask for builtins.currentSystem -- so the same file gives an
# x86_64-linux toolchain when CI builds it on a Linux runner. Neither build emulates
# anything; each is native to the machine that ran it. The registry tag carries the
# architecture to keep the two apart; see .github/workflows/toolchain-image.yml.
#
# openXC7 is distributed as a Nix flake, so Nix runs *inside* this image. It is
# not installed on the Mac, and `podman rmi` removes every trace.
#
# The flake's dev shell (`nix develop`) is deliberately not used. It also pulls
# in fpga-assembler, whose Bazel dependency tarball currently fails its
# fixed-output hash check on aarch64, and a GHDL-based VHDL frontend this
# project has no use for. Installing just the packages we need sidesteps both.

FROM docker.io/nixos/nix:latest

# Pin this to a revision (github:openxc7/toolchain-nix/<rev>) if you want the
# image to be reproducible over time.
ARG FLAKE=github:openxc7/toolchain-nix
ARG DBPART=xc7a35tcpg236
ARG DEVICE=xc7a35tcpg236-1

# cores=4 with max-jobs=1: compiling nextpnr-xilinx needs roughly 2 GB per
# translation unit, and the default (one job per core) OOM-kills cc1plus on a
# podman machine with the usual 4 GB. See the README for `podman machine set`.
RUN printf 'experimental-features = nix-command flakes\nmax-jobs = 1\ncores = 4\n' \
      >> /etc/nix/nix.conf

# The tools. --inputs-from keeps yosys and friends on the same pinned nixpkgs as
# the openXC7 packages instead of resolving a second, unrelated one. The base
# image's profile already provides bash, coreutils, grep and findutils; adding
# them again is a profile conflict, so only make and sed are listed here.
RUN nix profile install --inputs-from $FLAKE \
      "$FLAKE#nextpnr-xilinx" \
      "$FLAKE#prjxray" \
      nixpkgs#yosys \
      nixpkgs#gnumake \
      nixpkgs#gnused

# Python for prjxray's fasm2frames. nixpkgs' python3.12-fasm propagates only
# textX, while fasm/parser/__init__.py imports pyximport unconditionally and
# prjxray itself wants yaml, numpy and intervaltree -- so spell the environment
# out rather than relying on the packages' own dependency closures.
RUN nix build --impure --out-link /opt/pyenv --expr "\
  let \
    f = builtins.getFlake \"$FLAKE\"; \
    pkgs = import f.inputs.nixpkgs { system = builtins.currentSystem; }; \
  in pkgs.python312.withPackages (ps: [ \
       f.packages.\${builtins.currentSystem}.fasm \
       ps.cython ps.pyyaml ps.numpy ps.intervaltree \
       ps.simplejson ps.progressbar2 ps.textx ps.sortedcontainers \
     ])"

# The chip database for our part. The prebuilt nextpnr-xilinx-chipdb.artix7
# package covers 17 Artix-7 parts but omits every xc7a35t variant, even though
# prjxray-db describes them -- so generate this one ourselves, exactly the way
# upstream's chipdb derivation does. pypy3 is only needed here, and `nix store
# gc` drops it again afterwards.
RUN mkdir -p /opt/chipdb \
 && nix shell --inputs-from $FLAKE nixpkgs#pypy3 --command \
      pypy3 /root/.nix-profile/share/nextpnr/python/bbaexport.py \
        --device $DEVICE --bba /tmp/$DBPART.bba \
 && bbasm -l /tmp/$DBPART.bba /opt/chipdb/$DBPART.bin \
 && rm -f /tmp/$DBPART.bba \
 && nix store gc

ENV NEXTPNR_XILINX_DIR=/root/.nix-profile/share/nextpnr
ENV PRJXRAY_DB_DIR=/root/.nix-profile/share/nextpnr/external/prjxray-db
ENV CHIPDB=/opt/chipdb
ENV PYTHONPATH=/opt/pyenv/lib/python3.12/site-packages:/root/.nix-profile/usr/share/python3

WORKDIR /work
CMD ["make", "-f", "syn/openxc7.mk"]
