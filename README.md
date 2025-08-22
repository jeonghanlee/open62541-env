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
sudo dnf install git gcc pkg-config cmake python3 openssl3 openssl3-devel compat-openssl10

```

## About
This repository helps to build the `open62541` package and its customized application consistently on Linux.

## Commands

By default, everything will be within `${HOME}/open62541` path. It can be customized via

```bash
echo "INSTALL_LOCATION=where...." > configure/CONFIG_SITE.local
```

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


* Others

```bash
make uninstall
make clean
make distclean
make exist
make exist LEVEL=3
```

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

We can check whether we have `SONAME` or not

```
readelf -d open62541-src/build/bin/libopen62541.so
```

## Reference
* https://www.open62541.org/doc/master/building.html#main-build-options
