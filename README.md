# OPEN62541 Configuration Environment

An open source implementation of OPC UA (`open62541`) Configuration Environment and its customized application.

* The source codes are located in <https://github.com/open62541/open62541>
* Required packages (Debian and its variants) as follows

```bash
sudo apt-get install git build-essential gcc pkg-config cmake python3

# enable additional features
sudo apt-get install cmake-curses-gui     # for the ccmake graphical interface
sudo apt-get install libmbedtls-dev       # for encryption support
sudo apt-get install check libsubunit-dev # for unit tests
sudo apt-get install libpcap-dev          # for network-replay unit tests
sudo apt-get install python3-sphinx graphviz  # for documentation generation
sudo apt-get install python3-sphinx-rtd-theme # documentation style
sudo apt-get install libavahi-client-dev libavahi-common-dev # for LDS-ME (multicast discovery)

```

## About
This repository helps to build the `open62541` package and its customized application consistently on Linux.

## Commands

By default, everything will be within `/usr/local` path. It can be customized via

```bash
echo "INSTALL_LOCATION=where...." > configure/CONFIG_SITE.local
```

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
```

