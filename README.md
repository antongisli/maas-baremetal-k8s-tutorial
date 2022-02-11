# Bare metal Kubernetes with MAAS, LXD, and Juju

## Intro

This is a series of commands and configuration files that will guide you to build your own emulated bare metal k8s cluster on a single machine, using https://maas.io.

It is designed to be used in conjunction with an explanatory video tutorial: https://www.youtube.com/watch?v=sLADei_c9Qg

## How to use

Read maas-setup.sh. The script is not fully automated and requires manual intervention at times. Read the comments to understand the process.

## Requirements

You need a reasonably powerful **bare metal** machine, 4 or more cores with 32 GB of RAM and 500GB of free disk space. Assumes a fresh install of Ubuntu server (20.04 or higher) on the machine. 

The reason you need a bare metal machine is because nesting multiple layers of VMs will not work and/or have performance problems.

Note: this tutorial has not been tested on versions prior to 20.04.
