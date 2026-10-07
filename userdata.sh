#!/bin/bash
dnf -y update
dnf -y install htop nginx
systemctl enable --now nginx