#!/bin/zsh

# Simulates, builds and programs FPGA designs in the current folder with the
# tools in the container, e.g. from a terminal or VS Code tasks:
#   fpga sim <testbench> [time]   simulate, waveforms go to build/sim/<testbench>.vcd
#   fpga build [top]              build a bitstream into build/, from the Vivado
#                                 project (.xpr) if there is one, else from the sources
#   fpga program [bitstream]      program the board over its FTDI USB-JTAG
#   fpga init                     add VS Code tasks and a VHDL LS config to this folder
# The part for builds without a Vivado project can be set with FPGA_PART.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

fpga_part=${FPGA_PART:-xc7z010clg400-1}
xilinx="$script_dir/xilinx.sh"
build_dir="$PWD/build"

function usage {
	f_echo "Usage: fpga sim <testbench> [time] | fpga build [top] | fpga program [bitstream] | fpga init"
	exit 1
}

# Lists the files in the current folder, skipping hidden folders,
# build output and the copies Vivado generates
function find_files {
	find "$PWD" -type d \( -name '.?*' -o -name build -o -name xsim.dir \
		-o -name '*.sim' -o -name '*.runs' -o -name '*.gen' -o -name '*.cache' \
		-o -name '*.hw' -o -name '*.ip_user_files' \) -prune -o -type f -print
}

# Sorts VHDL files so that packages and entities are compiled before the
# files that use them, which xvhdl requires
function order_vhdl {
	python3 - "$@" << 'EOF'
import re, sys
files = sys.argv[1:]
declared, needs = {}, {}
for f in files:
	text = re.sub(r"--[^\n]*", "", open(f, errors="ignore").read()).lower()
	for name in re.findall(r"^\s*(?:entity|package)\s+(\w+)\s+is\b", text, re.M):
		declared.setdefault(name, f)
	needs[f] = set(re.findall(r"\bwork\s*\.\s*(\w+)", text))
	needs[f] |= set(re.findall(r"^\s*architecture\s+\w+\s+of\s+(\w+)", text, re.M))
	needs[f] |= set(re.findall(r"^\s*package\s+body\s+(\w+)", text, re.M))
ordered, visiting = [], set()
def visit(f):
	if f in ordered or f in visiting:
		return
	visiting.add(f)
	for name in sorted(needs[f]):
		if declared.get(name, f) != f:
			visit(declared[name])
	visiting.discard(f)
	ordered.append(f)
for f in files:
	visit(f)
print("\n".join(ordered))
EOF
}

function cmd_sim {
	local tb=$1 sim_time=${2:-all}
	if [ -z "$tb" ]
	then
		usage
	fi
	local sim_dir="$build_dir/sim"
	mkdir -p "$sim_dir"
	local sources=(${(f)"$(find_files)"})
	local vhdl=(${(M)sources:#*.(vhd|vhdl)})
	local verilog=(${(M)sources:#*.v})
	local sverilog=(${(M)sources:#*.sv})
	if (( $#vhdl ))
	then
		vhdl=(${(f)"$(order_vhdl $vhdl)"})
	fi

	# All steps run in one container, since each start takes a moment
	{
		echo "set -e"
		echo "cd ${(q)sim_dir}"
		(( $#verilog )) && echo xvlog ${(q)verilog}
		(( $#sverilog )) && echo xvlog --sv ${(q)sverilog}
		(( $#vhdl )) && echo xvhdl ${(q)vhdl}
		echo "xelab work.$tb -debug typical -s ${tb}_sim"
		echo "xsim ${tb}_sim -tclbatch wave.tcl"
	} > "$sim_dir/run.sh"
	cat > "$sim_dir/wave.tcl" << EOF
open_vcd {$sim_dir/$tb.vcd}
log_vcd [get_objects -r *]
run $sim_time
close_vcd
quit
EOF
	if "$xilinx" bash "$sim_dir/run.sh"
	then
		f_echo "Waveforms written to build/sim/$tb.vcd"
	else
		f_echo "Simulation failed."
		exit 1
	fi
}

# Prints its arguments as a Tcl list, so that paths may contain spaces
function tcl_list {
	local item
	for item in "$@"
	do
		printf '{%s} ' "$item"
	done
}

function cmd_build {
	local top=$1
	mkdir -p "$build_dir"
	local tcl="$build_dir/build.tcl"
	local projects=(${(M)${(f)"$(find_files)"}:#*.xpr})
	if (( $#projects > 1 ))
	then
		f_echo "There are several Vivado projects in this folder. Run fpga build from the folder of one of them."
		exit 1
	elif (( $#projects == 1 ))
	then
		f_echo "Building the Vivado project ${projects[1]:t}"
		cat > "$tcl" << EOF
open_project {${projects[1]}}
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
	# The run logs hold the actual errors
	foreach run {synth_1 impl_1} {
		set log [file join [get_property DIRECTORY [get_runs \$run]] runme.log]
		if {[file exists \$log]} {
			set f [open \$log]
			foreach line [split [read \$f] "\n"] {
				if {[regexp {^(ERROR|CRITICAL WARNING):} \$line]} { puts \$line }
			}
			close \$f
		}
	}
	puts "ERROR: The build failed."
	exit 1
}
foreach bit [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.bit]] {
	file copy -force \$bit {$build_dir}
}
EOF
	else
		if [ -z "$top" ]
		then
			f_echo "Without a Vivado project, the top-level entity is needed: fpga build <top>"
			exit 1
		fi
		f_echo "Building $top for $fpga_part"
		local files=(${(f)"$(find_files)"})
		# Testbenches are not synthesized
		local sources=(${files:#*(_tb|_testbench).*})
		sources=(${sources:#*/tb_*})
		local vhdl=(${(M)sources:#*.(vhd|vhdl)})
		local verilog=(${(M)sources:#*.v})
		local sverilog=(${(M)sources:#*.sv})
		local xdc=(${(M)sources:#*.xdc})
		{
			(( $#vhdl )) && echo "read_vhdl [list $(tcl_list $vhdl)]"
			(( $#verilog )) && echo "read_verilog [list $(tcl_list $verilog)]"
			(( $#sverilog )) && echo "read_verilog -sv [list $(tcl_list $sverilog)]"
			(( $#xdc )) && echo "read_xdc [list $(tcl_list $xdc)]"
			cat << EOF
synth_design -top $top -part $fpga_part
opt_design
place_design
route_design
report_utilization -file {$build_dir/utilization.rpt}
report_timing_summary -file {$build_dir/timing.rpt}
write_bitstream -force {$build_dir/$top.bit}
EOF
		} > "$tcl"
	fi
	if "$xilinx" vivado -mode batch -nojournal -log "$build_dir/vivado.log" -source "$tcl"
	then
		f_echo "Bitstream written to build/"
	else
		f_echo "The build failed."
		exit 1
	fi
}

# Prints the product ID of the first FTDI USB device (vendor ID 0x0403)
function ftdi_product_id {
	system_profiler SPUSBDataType -json 2> /dev/null | python3 -c '
import json, sys
def walk(items):
	for item in items:
		yield item
		yield from walk(item.get("_items", []))
for item in walk(json.load(sys.stdin).get("SPUSBDataType", [])):
	if item.get("vendor_id", "").startswith("0x0403"):
		print(item.get("product_id", "").split()[0])
		break'
}

function cmd_program {
	local bit=$1
	if [ -z "$bit" ]
	then
		# Newest bitstream in build/, else anywhere in the project
		local bits=("$build_dir"/*.bit(Nom) **/*.bit(Nom))
		bit=$bits[1]
	fi
	if ! [ -f "$bit" ]
	then
		f_echo "No bitstream found. Run fpga build first or pass the .bit file."
		exit 1
	fi
	bit=${bit:A}
	mkdir -p "$build_dir"

	# Forward the board's USB-JTAG to the container unless start_container.sh already does
	local xvcd_pid=""
	if ! pgrep -x xvcd > /dev/null
	then
		local product=$(ftdi_product_id)
		if [ -z "$product" ]
		then
			f_echo "No FTDI USB-JTAG found. Is the board connected and switched on?"
			exit 1
		fi
		"$script_dir/xvcd/bin/xvcd" -V 0x0403 -P "$product" -i "${FPGA_JTAG_INTERFACE:-0}" > "$build_dir/xvcd.log" 2>&1 &
		xvcd_pid=$!
		sleep 1
		if ! kill -0 $xvcd_pid 2> /dev/null
		then
			f_echo "Could not open the USB-JTAG (product ID $product):"
			cat "$build_dir/xvcd.log"
			exit 1
		fi
		trap "kill $xvcd_pid 2> /dev/null" EXIT
	fi

	local tcl="$build_dir/program.tcl"
	cat > "$tcl" << EOF
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target -xvc_url host.docker.internal:2542
set device [lindex [get_hw_devices -filter {PART =~ xc7*}] 0]
if {\$device eq ""} {
	puts "ERROR: No 7-series device on the JTAG chain, found: [get_hw_devices]"
	exit 1
}
current_hw_device \$device
set_property PROGRAM.FILE {$bit} \$device
program_hw_devices \$device
puts "Programmed \$device with {$bit}"
close_hw_target
disconnect_hw_server
close_hw_manager
EOF
	if ! "$xilinx" vivado -mode batch -nojournal -nolog -source "$tcl"
	then
		f_echo "Programming failed."
		exit 1
	fi
}

function cmd_init {
	local fpga_bin="${script_dir:h}/bin/fpga"
	mkdir -p .vscode
	if [ -f .vscode/tasks.json ]
	then
		f_echo ".vscode/tasks.json already exists, not changing it."
	else
		sed "s|@FPGA@|$fpga_bin|g" "$script_dir/templates/tasks.json" > .vscode/tasks.json
		f_echo "Added .vscode/tasks.json"
	fi
	if [ -f vhdl_ls.toml ]
	then
		f_echo "vhdl_ls.toml already exists, not changing it."
	else
		cp "$script_dir/templates/vhdl_ls.toml" vhdl_ls.toml
		f_echo "Added vhdl_ls.toml"
	fi
	# Keep Vivado's output out of Git
	touch .gitignore
	local line
	for line in ${(f)"$(< "$script_dir/templates/gitignore")"}
	do
		if ! grep -qxF -- "$line" .gitignore
		then
			echo "$line" >> .gitignore
		fi
	done
	f_echo "Updated .gitignore"
}

command=$1
shift 2> /dev/null
case $command in
	sim) cmd_sim "$@" ;;
	build) cmd_build "$@" ;;
	program) cmd_program "$@" ;;
	init) cmd_init "$@" ;;
	*) usage ;;
esac
