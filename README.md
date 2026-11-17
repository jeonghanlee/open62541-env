# OPEN62541 Configuration Environment

[![Debian 12](https://github.com/jeonghanlee/open62541-env/actions/workflows/debian12.yml/badge.svg)](https://github.com/jeonghanlee/open62541-env/actions/workflows/debian12.yml)
[![Rocky8](https://github.com/jeonghanlee/open62541-env/actions/workflows/rocky8.yml/badge.svg)](https://github.com/jeonghanlee/open62541-env/actions/workflows/rocky8.yml)

An open source implementation of OPC UA (`open62541`) Configuration Environment and its customized application.

* The source codes are located in <https://github.com/open62541/open62541>

## Required packages

* Debian and its variants

```bash
sudo apt install git build-essential gcc pkg-config cmake python3 libssl3 libssl-dev

```

* Redhat and its variants

```bash
sudo dnf install git gcc pkg-config cmake python3 patch openssl3 openssl3-devel compat-openssl10

```

## About
This repository helps to build the `open62541` package and its customized application consistently on Linux.

## Commands

By default, everything will be within `/usr/local` path. It can be customized via

```bash
echo "INSTALL_LOCATION=where...." > configure/CONFIG_SITE.local
```

Additional cmake options reach every conf target (`conf`, `conf.rocky8`, `conf.rocky10` and `conf.static`) through `CMAKE_EXTRA_OPTIONS`, which is empty by default, for example `make conf CMAKE_EXTRA_OPTIONS=-DUA_ENABLE_AMALGAMATION=OFF`. cmake keeps the options in `open62541-src/build/CMakeCache.txt`, so a value given once stays in effect for later `make conf` runs; give a new value to change it, or run `make distclean` and `make init` to start without it. cmake does not reject an option name it does not know: it stores the value as given, so check the name in `CMakeCache.txt`.

This enviornment only build shared library version only.

* Build

```bash
make init
make conf
make build
make install
```

* Build on Rocky 8 or Red Hat Variant

Even if their compiler and linker is indeed very mordern, Red Hat made a choice to build their binutils packages to default to the order `RPATH` instead of `RUNPATH`. So we have to enable it by using the red hat specific configuration option.


```bash
make init
make conf.rocky8
make build
make install
```

* Build on Rocky 10

`conf.rocky10` calls the same configuration recipe as `conf.rocky8`. Both
targets retain the Red Hat linker settings and the configured installation
prefix. Existing calls to `conf.rocky8` remain supported.

```bash
make init
make conf.rocky10
make build
make install
```


* Others

```bash
make uninstall
make clean
make distclean
make exist
make exist LEVEL=3
```

`make uninstall` removes exactly the files listed in `open62541-src/build/install_manifest.txt`, which `make install` writes. They are removed from the installation prefix that `make conf` stored in `open62541-src/build/CMakeCache.txt`; an `INSTALL_LOCATION` given to `make uninstall` is not used. Directories that become empty are removed; every other file in that prefix is kept. The target does not call `sudo`; run it with the rights that this prefix requires. Run it before `make distclean`, which removes the source directory `open62541-src` together with the manifest; without the manifest `make uninstall` prints a notice and removes nothing.

## Redhat variant OS

The default makefile rule installs all library files within `CMAKE_INSTALL_PREFIX/lib64`. This creates a cumbersome situation because we then have to link these libraries within the ALS-U EPICS environment.
Therefore, within this environment, we are forced to use `CMAKE_INSTALL_PREFIX/lib` instead. If you intend to use this environment with a Red Hat variant OS, please ensure that the installation location `lib` is compatible.

## `github.com/opcua` `INSTALL` option workaround

We should remove `SONAME` within `libopen62541.so` in order to use `OPEN62541_DEPLOY_MODE = INSTALL`.
Please check the Issue at https://github.com/epics-modules/opcua/issues/190

```bash
make init
make patch.apply
make conf
make build
make install
```

Run `make patch.apply` after `make init` and before `make conf`. Both `make patch.apply` and `make patch.revert` classify the patch with `patch --dry-run` before they change anything, so either can run again at any time: `make patch.apply` applies an unapplied patch and, for an applied patch, says so and changes nothing; `make patch.revert` reverses an applied patch and skips an unapplied one. A state that is neither, for example a partly applied patch, stops with an error and changes nothing; `make distclean` followed by `make init` starts from a clean source. When no patch file `patch/<SRC_VERSION>.p0.patch` exists for the version, both targets print a notice and change nothing.

`make patch.apply` and `make patch.revert` run `scripts/apply_patch.bash` and `scripts/revert_patch.bash`, copies of the apply and revert tools of the `patch` skill, which the dev-env repository (https://github.com/jeonghanlee/dev-env) holds under `shared/skills/patch`. `scripts/apply_patch.bash.source` and `scripts/revert_patch.bash.source` record the commit and the digest each copy was taken from. Do not edit a copy; a change of a tool is proposed to the owner of the dev-env repository, which holds the originals.

We can check whether we have `SONAME` or not

```
readelf -d open62541-src/build/bin/libopen62541.so
```

## Reference
* https://www.open62541.org/doc/master/building.html#main-build-options
