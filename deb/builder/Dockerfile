# Builder image for the gufo (.deb) lane.
#
#   podman build -t gufo-deb-builder deb/builder
#   podman run --rm --memory 8g --memory-swap 0 -v "$PWD:$PWD" -w "$PWD" gufo-deb-builder \
#     deb/build-deb --in-container
#
# The ROCm series appears exactly once, as an ARG. It is here at all because the build needs
# hip-dev and rocm-llvm, and Debian ships neither -- so a builder has to name AMD's repository
# somewhere. Naming it through an argument means a new ROCm line is a flag on the build command,
# not a commit in this repository:
#
#   --build-arg ROCM_SERIES=7.2.5      (or the next line, when it is qualified)
#
# The installed package takes no such position. Which ROCm a host runs, and how it is kept there,
# is a deployment decision and is proposed separately; see deb/README.md.
ARG APT_IMAGE=debian:trixie
FROM ${APT_IMAGE}

ARG ROCM_SERIES=7.2.4
ARG DEBIAN_FRONTEND=noninteractive

# AMD publishes Ubuntu suites in this repository and, for the current line, no Debian suite. So a
# Debian builder asks for the Ubuntu suite that matches the glibc it has (bookworm -> jammy,
# trixie -> noble). That is the same compromise the installed runtime faces, and it is the reason
# this stays a build-time image: a build chroot that keeps that suite enabled turns a future
# apt-get upgrade into a cross-distribution resolution. The installed side of that decision is the
# repository-and-pin proposal, made separately.
RUN set -eux; \
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"; \
    case "${codename}" in \
      bookworm|trixie|sid) suite="$( [ "${codename}" = trixie ] || [ "${codename}" = sid ] && echo noble || echo jammy )" ;; \
      *) suite="noble" ;; \
    esac; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg; \
    curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key -o /tmp/rocm.gpg; \
    gpg --dearmor < /tmp/rocm.gpg > /etc/apt/keyrings/rocm.gpg; \
    printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/%s %s main\n' \
      "${ROCM_SERIES}" "${suite}" > /etc/apt/sources.list.d/rocm.list; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends \
      debhelper dpkg-dev cmake ninja-build pkg-config python3 git \
      libicu-dev libcurl4-openssl-dev libssl-dev libpng-dev libjpeg-dev libwebp-dev \
      libsndfile1-dev libsoxr-dev \
      rocm-llvm hip-dev hip-runtime-amd hipblas-dev hipblaslt-dev rocblas-dev \
      hipcub-dev rocprim-dev rocwmma-dev; \
    rm -rf /var/lib/apt/lists/*

# --parallel in debian/rules is capped by DEB_BUILD_OPTIONS, which deb/build-deb computes from
# the machine it runs on. Nothing here sets nproc-derived parallelism: an uncapped compile is
# how a build becomes an out-of-memory event for something else on the host.
WORKDIR /build
