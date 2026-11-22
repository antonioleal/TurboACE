# sjasmplus — local copy for TurboACE

This directory is a plain copy of the sjasmplus Z80 cross-assembler, used to build the
TurboACE ROM (`../../rom/Makefile` uses `../tools/sjasmplus/sjasmplus`). It is not a git clone.

- Upstream: https://github.com/z00m128/sjasmplus
- Version: tag `v1.20.3`, commit `ecf387c0f2e5ea8d3a291724c1ae3de4d9705020` (2023-06-28)
- Bundled submodules at that commit:
  - `LuaBridge` 5d21e35633a1f87ed08af115b07d3386096f792b
  - `unittest-cpp` 10e50ad70c696002b1d5bbefd0ea04b3ea92a03b (with its `docs` wiki)
- Licence: BSD 3-clause, see `LICENSE.md`.

Build (needs make and g++):

```
make -C tools/sjasmplus
```

The binary (`tools/sjasmplus/sjasmplus`) and `build/` are build output and not kept in git
(see this directory's `.gitignore`, from upstream).

Removed from the upstream tree (CI and GitHub project files, unused here):
`.github/`, `LuaBridge/.github/`, `.cirrus.yml`, `unittest-cpp/.travis.yml`,
`unittest-cpp/appveyor.yml`, `LuaBridge/third_party/gtest/.travis.yml`,
`LuaBridge/third_party/gtest/appveyor.yml`. The `.gitattributes` files are kept.
