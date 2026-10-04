#!/bin/bash

# This runs the Vivado installer in batch mode.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_linux


install_bin_path=$(tr -d "\n\r\t " < "/home/user/scripts/install_bin")

file_hash=($(md5sum "$install_bin_path"))
if ! set_vivado_version_from_hash "$file_hash"
then
	# version confirmed by the user during setup.sh
	vivado_version=$(tr -d "\n\r\t " < "/home/user/scripts/install_version")
fi
if [ -z "$vivado_version" ]
then
	f_echo "Invalid installer hash"
	exit 1
fi

# Extract installer
f_echo "Extracting installer"
eval "$install_bin_path --target /home/user/installer --noexec"

# Versions without a bundled config get one from the installer itself,
# since module names change between releases
install_config="/home/user/scripts/install_configs/${vivado_version}.txt"
if ! [ -f "$install_config" ]
then
	f_echo "No install configuration for $vivado_version yet. Choose the product (Vivado, or Vitis which includes Vivado) and edition:"
	rm -f /home/user/.Xilinx/install_config.txt
	if ! /home/user/installer/xsetup -b ConfigGen || ! [ -f /home/user/.Xilinx/install_config.txt ]
	then
		f_echo "Generating the install configuration failed."
		exit 1
	fi
	sed -e "s|^Destination=.*|Destination=/home/user/Xilinx|" \
		-e "s|^EnableDiskUsageOptimization=.*|EnableDiskUsageOptimization=1|" \
		/home/user/.Xilinx/install_config.txt > "$install_config"
	if ! grep -q "^EnableDiskUsageOptimization=" "$install_config"
	then
		echo "EnableDiskUsageOptimization=1" >> "$install_config"
	fi
	f_echo "The configuration was saved to scripts/install_configs/${vivado_version}.txt"
	f_echo "To save disk space, open it on macOS now and set every device family you do not need in the Modules line from :1 to :0 (e.g. keep only Zynq-7000 for a Zynq-7000 board)."
	wait_for_user_input
fi

# Get AuthToken by repeating the following command until it succeeds
f_echo "Log into your Xilinx account to download the necessary files."
while ! /home/user/installer/xsetup -b AuthTokenGen
do
	f_echo "Your account information seems to be wrong. Please try logging in again."
	sleep 1
done

# Run installer
f_echo "You successfully logged into your account. The installation will begin now."
eula_args="XilinxEULA,3rdPartyEULA"

# Check if the version is 202110 to include WebTalk terms
if [ "$vivado_version" = "202110" ]; then
    eula_args="${eula_args},WebTalkTerms"
    f_echo "Note: The 2021.1 version enables WebTalk data collection and agrees automatically to the corresponding terms."
    f_echo "For more information, see: https://docs.amd.com/r/2021.1-English/ug973-vivado-release-notes-install-license/WebTalk-Participation"
    wait_for_user_input
fi

if /home/user/installer/xsetup -c "$install_config" -b Install -a "${eula_args}"
then
    # The extracted installer is only needed for the installation
    rm -rf /home/user/installer
    f_echo "Vivado was successfully installed."
    f_echo "Run start_container.sh to launch it."
else
    f_echo "An error occurred during installation. Please run cleanup.sh and try again."
    exit 1
fi