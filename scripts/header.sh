# general functions and definitions used by the other scripts

# This script needs to be sourced into other scripts or
# be run explicitly with an interpreter since it has no shebang

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/hashes.sh"

# echo with color
function f_echo {
	echo -e "\e[1m\e[33m$1\e[0m"
}

# aborts the script if it isn't run on macOS
function validate_macos {
    if [[ $(uname) == *Darwin* ]]
    then
        :
    else
        f_echo "Make sure to run this script on macOS."
        exit 1
    fi
}

# aborts the script if it isn't run inside the Docker container
function validate_linux {
    if [[ $(uname) == *Linux* ]]
    then
        :
    else
        f_echo "Make sure to run this script on Linux."
        exit 1
    fi
}

function validate_internet {
    if ! ping -q -c1 google.com &>/dev/null
    then
        f_echo "Internet connection required."
        exit 1
    fi
}

function wait_for_user_input {
    f_echo "Press Enter to continue..."
    read
}

# Both OrbStack and Docker Desktop provide the docker CLI.
# OrbStack is preferred if installed since it needs less memory.
function uses_orbstack {
    [ -d "/Applications/OrbStack.app" ]
}

function start_docker {
    # check if Docker is installed
    if ! which docker &> /dev/null
    then
        f_echo "You need to install OrbStack or Docker Desktop first."
        exit 1
    fi

    # Launch Docker daemon
    f_echo "Launching Docker daemon..."
    sleep 2
    # Wait for Docker to start
    while ! docker ps &> /dev/null
    do
        if uses_orbstack
        then
            orb start &> /dev/null
        else
            open -a Docker
        fi
        sleep 5
    done
    sleep 2
}

function stop_docker {
    if uses_orbstack
    then
        orb stop &> /dev/null
        return
    fi
    curl -s -X POST -H 'Content-Type: application/json' -d '{ "openContainerView": true }' -kiv --unix-socket "$HOME/Library/Containers/com.docker.docker/Data/backend.sock" http://localhost/engine/stop &> /dev/null
    osascript -e 'quit app "Docker Desktop"'
    sleep 2
}

vivado_version=""

function set_vivado_version_from_hash {
    if [[ -v web_hashes[$1] ]]
    then
        vivado_version=${web_hashes[$1]}
    elif [[ -v sfd_hashes[$1] ]]
    then
        vivado_version=${sfd_hashes[$1]}
    else
        return 1
    fi
    return 0
}

# Fallback for installers whose hash isn't known yet, e.g.
# FPGAs_AdaptiveSoCs_Unified_2024.2_1113_1001_Lin64.bin -> 202420
function set_vivado_version_from_filename {
    local file_name=$(basename "$1")
    if [[ $file_name =~ _(20[0-9][0-9])\.([0-9])_[0-9_]*Lin64\.bin$ ]]
    then
        if [ -n "$BASH_VERSION" ]
        then
            vivado_version="${BASH_REMATCH[1]}${BASH_REMATCH[2]}0"
        else
            vivado_version="${match[1]}${match[2]}0"
        fi
        return 0
    fi
    return 1
}

# The actual resolution is stored in the file vnc_resolution
vnc_default_resolution="1920x1080"

# Prints the size of the main display in pixels and its scale factor,
# e.g. "2880x1800 2" for a Retina display that looks like 1440x900
function main_display_mode {
    osascript -l JavaScript -e 'ObjC.import("AppKit");
        var s = $.NSScreen.screens.objectAtIndex(0), k = s.backingScaleFactor;
        (s.frame.size.width * k) + "x" + (s.frame.size.height * k) + " " + k' 2> /dev/null
}

current_user=$(whoami)
