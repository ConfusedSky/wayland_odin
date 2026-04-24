#!/bin/env bash
set -euo pipefail

odin build ./wayland_gen -out:dist/wayland_gen
./dist/wayland_gen /usr/share/wayland/wayland.xml ./src/wayland_protocol/
./dist/wayland_gen /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml ./src/wayland_protocol/
./dist/wayland_gen /usr/share/wayland-protocols/stable/linux-dmabuf/linux-dmabuf-v1.xml ./src/wayland_protocol
