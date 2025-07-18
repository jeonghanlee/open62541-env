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

* Others

```bash
make uninstall
make clean
make distclean
make exist
make exist LEVEL=3
```

