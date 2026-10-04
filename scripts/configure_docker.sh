#!/bin/zsh

# Attempts to configure OrbStack or Docker Desktop by enabling Rosetta
# and increasing memory and swap

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

# Vivado synthesis easily exceeds the default of half the host memory on 8 GB Macs
minMemory=5120
minSwap=4096

function cannot_setup_docker {
    f_echo "Unfortunately, the script could not configure Docker automatically."
    f_echo "This means that you have to change the settings in the Docker Dashboard yourself:"
    f_echo "Enable the Virtualization Framework and Rosetta emulation, set Memory to at least $((minMemory / 1024)) GiB and Swap to at least $((minSwap / 1024)) GiB."
    f_echo "Restart Docker after applying the changes and then continue with the installation."
    wait_for_user_input
    exit 1
}

stop_docker

if uses_orbstack
then
    # OrbStack manages swap itself
    if orb config set rosetta true && orb config set memory_mib $minMemory
    then
        f_echo "Configured OrbStack successfully"
        exit 0
    fi
    f_echo "Unfortunately, the script could not configure OrbStack automatically."
    f_echo "Open OrbStack's settings, enable Rosetta and set the memory limit to at least $((minMemory / 1024)) GiB."
    wait_for_user_input
    exit 1
fi

# Newer Docker Desktop versions store their settings in settings-store.json with capitalized keys
docker_settings_dir="$HOME/Library/Group Containers/group.com.docker"
docker_settings_file="$docker_settings_dir/settings-store.json"
if ! [ -f "$docker_settings_file" ]
then
    docker_settings_file="$docker_settings_dir/settings.json"
fi
if ! [ -f "$docker_settings_file" ]
then
    cannot_setup_docker
fi

if ! python3 - "$docker_settings_file" $minMemory $minSwap <<'EOF'
import json, sys
path, min_memory, min_swap = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path) as f:
    settings = json.load(f)
is_store = path.endswith("settings-store.json")

def set_key(name, update):
    for key in settings:
        if key.lower() == name.lower():
            settings[key] = update(settings[key])
            return
    # settings-store.json omits keys that are still at their default
    if not is_store:
        sys.exit(1)
    settings[name[0].upper() + name[1:]] = update(None)

set_key("useVirtualizationFramework", lambda _: True)
set_key("useVirtualizationFrameworkRosetta", lambda _: True)
set_key("memoryMiB", lambda v: max(v or 0, min_memory))
set_key("swapMiB", lambda v: max(v or 0, min_swap))
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
EOF
then
    cannot_setup_docker
fi

f_echo "Configured Docker successfully"
