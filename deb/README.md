# Debian package lane

Builds the `gufo` `.deb` from the engine repository. This lane is a tool, not a release artifact:
it holds no version, no changelog and no distribution of any particular machine, so a new
upstream release costs nothing here.

## Scope, and why it is this small

The package contains the executable, the runtime data the executable is compiled to look for, the
licenses, and one line of linker configuration. It installs **no systemd unit, no launcher, no
configuration file, no user, and it opens no port**. Service integration, environment-based
configuration, model and cache management, deployment helpers and any custom upgrade handling are
deliberately absent: they are deployment choices, and they are proposed as separate changes so
they can be reviewed as deployment choices.

Two consequences, stated where they will be read rather than discovered later:

* **Nothing starts the engine after installation.** Run `gufo serve` yourself, or take the service
  lane when it exists. A host that upgrades to this package and expects something to listen on a
  port will find nothing listening, and that is the intended behaviour.
* **The dependency is unresolvable on a stock Debian host.** `hipblas`, `hipblaslt`, `rocblas`
  and `hip-runtime-amd` are not in Debian. Add AMD's ROCm apt repository first, or apt refuses
  the install — which is the correct outcome, because the alternative is installing a binary that
  cannot load.

## The two things this package has to get right

**Runtime libraries.** The binary links the ROCm runtime by soname and carries no `RUNPATH`:

```sh
readelf -d /usr/bin/gufo | grep -E 'RPATH|RUNPATH'      # nothing
ldd /usr/bin/gufo | grep -E 'hipblas|rocblas|amdhip64'  # /opt/rocm-<ver>/lib/...
```

so `debian/rocm.conf` installs `/etc/ld.so.conf.d/rocm.conf`, and `debian/triggers` activates
libc-bin's `ldconfig` trigger instead of shipping a maintainer script. That combination is proven
against its own negative control, each on a pristine `debian:trixie`, payload identical in shape:

| | no `triggers` | with `activate ldconfig` |
| --- | --- | --- |
| dpkg | *(no trigger line)* | `Processing triggers for libc-bin` |
| linker cache refreshed | no | **yes** |
| library indexed from the non-standard directory | 0 | **1** |

**Declared dependencies.** `${shlibs:Depends}` builds itself from the shlibs metadata that Debian
packages ship. How much of the ROCm runtime that covers is a property of the machine running the query,
not of this package — the same command returns one file on one host and several on a container built
against AMD's repository:

```sh
grep -l 'hipblas\|rocblas\|amdhip64' /var/lib/dpkg/info/*.shlibs
```

A dependency left to whatever `${shlibs:Depends}` happens to emit on the build machine is a dependency
that travels with that machine. So the ROCm runtime and `ffmpeg` are declared explicitly in
`debian/control`, floor by floor — floors, so a newer patch or major installs untouched — and
`debian/tests/smoke.sh` fails if any library in `NEEDED` is neither resolvable on the test host nor
named in `Depends`, reporting by name the ones that host cannot judge. `ffmpeg` is declared because the
binary executes it; nothing links it.

**Build dependencies are a different list, and they move.** Whatever the engine's `CMakeLists.txt`
marks `REQUIRED` has to appear in `Build-Depends` and in the builder image, or configure aborts with
*"The following required packages were not found"*. The audio decode libraries currently in that list are
named in `debian/control`; the list itself is upstream's to change, and this lane follows it by reading
`CMakeLists.txt` rather than by remembering a release number. That is not scope creep: this package is
lite about what it *installs*, which says nothing about what the engine needs to *compile*.
`dpkg-checkbuilddeps` is the check, and it costs seconds — run it before a build, not after.

## Building

```sh
deb/build-deb                              # newest tag. no argument, no bump, no edit
deb/build-deb v<tag>                      # a specific tag
deb/build-deb main --snapshot            # an untagged ref -> <ver>+git<sha>-1
deb/build-deb --dry-run                  # print the plan, run nothing
CPU_FLAGS=-march=<arch> deb/build-deb    # opt into codegen tuning for a fleet
```

`deb/build-deb` clones the ref into a scratch tree, assembles `deb/common/` into that checkout's
`debian/`, generates the minimal `debian/changelog` entry there from `version.txt` — the release
history stays in Gufo's own `CHANGELOG.md` and on the release page, this lane copies neither — and
builds. It writes nothing inside this repository and nothing inside a working copy of the engine.

### Parallelism is computed, not assumed

`dh_auto_build --parallel` falls back to `nproc` when the caller says nothing. This project's
heaviest translation units are HIP kernels at `-O3`, gigabytes apiece, so on a host holding model
weights in unified memory an uncapped build is an out-of-memory event that lands on whatever else
is running. `deb/build-deb` therefore reads `MemAvailable`, divides by a per-job estimate
(`PER_JOB_GiB`, default 3 — an estimate, printed so you can disagree with the arithmetic instead
of the number), caps at 16 and `nproc`, prints every input, and **refuses to start** when there
is no safe `-j`. `--in-container` adds `--memory`, which keeps that decision inside the
container's cgroup.

### Reproducing what CI does

```sh
podman build -t gufo-deb-builder deb/builder
podman run --rm --memory 8g --memory-swap 0 -v "$PWD:$PWD" -w "$PWD" gufo-deb-builder \
  ./deb/build-deb --in-container
./deb/tests/lite-scope.sh out/gufo_*_amd64.deb
```

## Gates

| gate | command | what it refuses |
| --- | --- | --- |
| scope | `deb/tests/lite-scope.sh` | a unit, `/etc/gufo`, a launcher, a maintainer script, a tracked changelog, a version or ROCm-series literal, a tuning flag in `rules` — and it injects each of those into a copy and requires itself to fail, because a gate nobody has watched fail is decoration |
| scope, against the artifact | `deb/tests/lite-scope.sh out/gufo_*_amd64.deb` | the same, on the bytes anyone would install |
| smoke | `deb/tests/smoke.sh` (autopkgtest) | an installed package whose `NEEDED` list names something neither resolvable nor declared, or that shipped a unit or a config |
| version | `deb/gen-deb-ver <checkout>` | an untagged checkout claiming a release version it does not carry |

## Not equivalent to the qualified Nix build

The Nix package applies `rocr-fixed-cwsr.patch` to ROCr. The ROCm runtime installed from AMD's apt
repository does not carry that patch. A host running this `.deb` is therefore running a different
ROCr than the one the project qualifies, and should not be described as equivalent to it under
load or otherwise. If equivalence is wanted, the fix is a patched ROCr in the packaging lane, not
a note in a README.

## Where things go

The build produces `gufo_<version>_<arch>.deb` plus its `.buildinfo` and `.changes`. Keep the
three together: names are parsed from the version at build start, and an artifact whose sidecars
name a different version is provenance that points at the wrong tree. Packages are intended to be
published as assets on the corresponding **Gufo release**; the upload step is gated on a
cross-repository credential and the lane publishes to its own workflow run without it.
