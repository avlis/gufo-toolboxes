# Debian release package

The Debian release flow will follow the Windows release flow:

1. Toolboxes passes an exact Gufo release tag to a reusable build workflow in
   the Gufo repository.
2. That workflow builds and validates a `.deb` and generates its SHA-256 checksum.
3. Toolboxes downloads the artifacts, verifies the checksum, and attaches both
   files to the matching release in `gufo-org/gufo`, using the existing release
   GitHub App.

The installed package must not require Nix or files under `/nix/store`.
Service setup, model downloads, and cache management remain outside this package.

This directory currently documents the intended flow only. The previous standalone
Debian source build, ROCm builder image, and publishing workflow have been removed.
The replacement build and package layout will be implemented in a follow-up step.
