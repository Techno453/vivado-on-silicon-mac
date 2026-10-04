#!/bin/zsh

# Runs a Xilinx tool (vivado, xvlog, xelab, xsim, vitis, ...) in a container
# without the GUI, from the current macOS folder, e.g.:
#   scripts/xilinx.sh vivado -mode batch -source build.tcl
# When called through one of the links in bin/ (e.g. bin/vivado),
# the tool is taken from the link name instead.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

tool=$(basename "$0")
if [[ $tool == xilinx.sh ]]
then
	if [ $# -eq 0 ]
	then
		f_echo "Usage: xilinx.sh <tool> [arguments...]"
		exit 1
	fi
	tool=$1
	shift
fi

if ! [ -d "$script_dir/../Xilinx" ]
then
	f_echo "Vivado is not installed yet. Run setup.sh first."
	exit 1
fi

if ! docker ps &> /dev/null
then
	start_docker
fi

# Only allocate a terminal when there is one, so that VS Code tasks and pipes work
tty_flags=(-i)
if [ -t 0 ] && [ -t 1 ]
then
	tty_flags=(-it)
fi

# The home folder (and the current folder, if outside of it) is mounted at the
# same path, so that file paths in scripts, logs and error messages match macOS
mounts=(--mount type=bind,source="$HOME",target="$HOME")
if [[ $PWD != $HOME && $PWD != $HOME/* ]]
then
	mounts+=(--mount type=bind,source="$PWD",target="$PWD")
fi

# The Vivado and, if installed, Vitis environments are loaded before running the tool.
exec docker run --init --rm "${tty_flags[@]}" \
	--mount type=bind,source="$script_dir/..",target="/home/user" \
	"${mounts[@]}" \
	--workdir "$PWD" --user user --env HOME=/home/user \
	--platform linux/amd64 x64-linux \
	bash -c 'for f in /home/user/Xilinx/Vivado/*/settings64.sh /home/user/Xilinx/Vitis/*/settings64.sh
	do
		if [ -f "$f" ]
		then
			source "$f"
		fi
	done
	exec "$@"' bash "$tool" "$@"
