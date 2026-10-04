#!/bin/zsh

# Initial setup on host (macOS) side

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
# Make sure that the script is run in macOS and not the Docker container
validate_macos

# Make sure permissions are right
if [[ "$current_user" == "root" ]]
then
	f_echo "Do not execute this script as root."
	exit 1
fi

# Make sure there are no previous installations in this folder
if [ -d "$script_dir/../Xilinx" ]
then
	f_echo "A previous installation was found. To reinstall, remove the Xilinx folder."
	exit 1
fi

validate_internet

f_echo "Advancing with the setup requires the following:"
f_echo "- Agreeing to Xilinx'/AMD's EULAs (which can be obtained by extracting the installation binary)"
f_echo "- Enabling WebTalk data collection for version 2021.1 and agreeing to corresponding terms"
f_echo "- Installation of Rosetta 2 and agreeing to Apple's corresponding software license agreement"
f_echo "Proceed [Y/n]?"
read user_consent
case $user_consent in
[yY]|[yY][eE]*)
	f_echo "Continuing setup..."
	;;
[nN]|[nN][oO]*)
	f_echo "Aborting setup."
	exit 1
	;;
*)
	f_echo "Invalid option."
	exit 1
	;;
esac

# Check if the Mac is Intel or Apple Silicon
if [[ "$(uname -m)" == "x86_64" ]]; then
	f_echo "Mac is Intel-based. Rosetta installation is not required."
else
	if arch -arch x86_64 uname -m > /dev/null 2>&1; then
		f_echo "Rosetta is already installed."
	else
		f_echo "Rosetta is not installed."
		f_echo "Proceeding with Rosetta installation..."
		if ! softwareupdate --install-rosetta --agree-to-license; then
			f_echo "Error installing Rosetta."
			exit 1
		fi
	fi
fi

# Get Vivado installation file
f_echo "You need to put the Vivado installation file into this folder if you have not done so already."
installation_binary=""
# The installation binary can also be passed as the first argument
installer_arg=$1
while true
do
	installation_binary=""
	# Get the absolute path to the file
	if [ -n "$installer_arg" ]
	then
		installation_binary=$installer_arg
		installer_arg=""
	else
		f_echo "Then, drag and drop the Vivado installation binary into this terminal window and press Enter: "
		read installation_binary
	fi
	# Some terminals wrap dropped paths in quotes and append a space
	installation_binary=$(printf '%s' "$installation_binary" | sed -E "s/^[[:space:]]+//; s/[[:space:]]+$//; s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/")
	if [ -n "$installation_binary" ]
	then
		installation_binary=${installation_binary:A}
	fi
	# check if it is accessible from the container
	parent_dir=$(dirname "$script_dir")
	if ! [[ $installation_binary == $parent_dir/* ]]
	then
		f_echo "You need to move the installation binary into the folder!"
		continue
	fi
	# check file hash
	file_hash=$(md5 -q "$installation_binary")
	if set_vivado_version_from_hash "$file_hash"
	then
		f_echo "Valid file provided. Detected version $vivado_version"
		break
	elif set_vivado_version_from_filename "$installation_binary"
	then
		f_echo "Detected version $vivado_version from the file name, but its hash is not known to this script."
		f_echo "MD5: $file_hash"
		f_echo "Compare it with the MD5 SUM listed on AMD's download page. Does it match [y/N]?"
		read hash_matches
		if [[ $hash_matches == [yY]* ]]
		then
			break
		fi
		f_echo "Download the installer again and retry."
		continue
	else
		f_echo "File corrupted or version not supported."
		continue
	fi
done
echo -n "$vivado_version" > "$script_dir/install_version"

# write file path to "install_bin"
install_bin_path="${installation_binary#$parent_dir}"
install_bin_path="/home/user$install_bin_path"
echo -n "$install_bin_path" > "$script_dir/install_bin"

# Make the user own the whole folder
if ! chown -R $current_user "$script_dir/.."
then
	f_echo "Higher privileges are required to make the folder owned by the user."
	if ! sudo chown -R $current_user "$script_dir/.."
	then
		f_echo "Error setting $current_user as owner of this folder."
		exit 1
	fi
fi

# Make the scripts executable
if xattr -p com.apple.quarantine "$script_dir/xvcd/bin/xvcd" &>/dev/null
then
	if ! xattr -d com.apple.quarantine "$script_dir/xvcd/bin/xvcd"
	then
		f_echo "You need to remove the quarantine attribute from $script_dir/xvcd/bin/xvcd manually."
		wait_for_user_input
	fi
fi

if ! chmod +x "$script_dir"/*.sh "$script_dir/xvcd/bin/xvcd" "$installation_binary"
then
	f_echo "Error making the scripts executable."
	exit 1
fi

# make sure that Docker is installed
start_docker

# Attempt to enable Rosetta and set swap to at least 2GiB in Docker
eval "$script_dir/configure_docker.sh"

# Generate the Docker image
if ! eval "$script_dir/gen_image.sh"
then
	exit 1
fi

# Set VNC resolution, matching the display so that text is sharp on Retina displays
read display_resolution ui_scale <<< "$(main_display_mode)"
if ! [[ $display_resolution =~ "^[0-9]+x[0-9]+$" && $ui_scale =~ "^[12]$" ]]
then
	display_resolution=$vnc_default_resolution
	ui_scale=1
fi
f_echo "Set the resolution of the container. Keep in mind that high resolutions might make text and images appear small."
f_echo "You can change the resolution and the UI scale (1 or 2) manually in the vnc_resolution and ui_scale files later."
f_echo "Press enter to match your display ($display_resolution at ${ui_scale}x scale) or type in your preference:"
read resolution
# if resolution has the right format
if [[ $resolution =~ "^[0-9]+x[0-9]+$" ]]
then
	f_echo "Setting $resolution as resolution"
	echo "$resolution" > "$script_dir/vnc_resolution"
else
	f_echo "Setting the default of $display_resolution"
	echo "$display_resolution" > "$script_dir/vnc_resolution"
fi
echo "$ui_scale" > "$script_dir/ui_scale"
echo ""

# copy de_start.desktop autostart file
mkdir -p "$script_dir/../.config/autostart"
cp "$script_dir/de_start.desktop" "$script_dir/../.config/autostart/de_start.desktop"
mkdir "$script_dir/../Desktop"

# Start container
f_echo "Now, the container is started (only terminal, no GUI) and the actual installation process begins."
eval "$script_dir/run_installer.sh"
