#!/bin/bash

# This script is run whenever the desktop environment has started.
# (with normal user privileges).

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_linux

export LD_PRELOAD="/lib/x86_64-linux-gnu/libudev.so.1 /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/libgdk-x11-2.0.so.0"

# if Vivado is installed
if [ -d "/home/user/Xilinx" ]
then
	# Make Vivado connect to the xvcd server running on macOS
	/home/user/Xilinx/Vivado/*/bin/hw_server -e "set auto-open-servers     xilinx-xvc:host.docker.internal:2542" &
	# Load the Vivado and, if installed, Vitis environments.
	# The Vitis IDE can be started from its desktop shortcut.
	for f in /home/user/Xilinx/Vivado/*/settings64.sh /home/user/Xilinx/Vitis/*/settings64.sh
	do
		if [ -f "$f" ]
		then
			source "$f"
		fi
	done
	vivado
else
	f_echo "The installation is incomplete."
	wait_for_user_input
fi