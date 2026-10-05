#!/bin/zsh

# Simulates, builds and programs FPGA designs in the current folder with the
# tools in the container, e.g. from a terminal or VS Code tasks:
#   fpga sim <testbench> [time]   simulate, waveforms go to build/sim/<testbench>.vcd;
#                                 with a Vivado project (.xpr), the testbench may be
#                                 empty ("") to use the project's simulation top
#   fpga build [top]              build a bitstream into build/, from the Vivado
#                                 project (.xpr) if there is one, else from the sources
#   fpga program [bitstream]      program the board over its FTDI USB-JTAG
#   fpga init                     add a VHDL LS config and .gitignore entries to this folder
#   fpga vhdl-ls                  only write the VHDL LS config (vhdl_ls.toml)
# The part for builds without a Vivado project can be set with FPGA_PART.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

fpga_part=${FPGA_PART:-xc7z010clg400-1}
xilinx="$script_dir/xilinx.sh"
build_dir="$PWD/build"

function usage {
	f_echo "Usage: fpga sim <testbench> [time] | fpga build [top] | fpga program [bitstream] | fpga init | fpga vhdl-ls"
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

# Simulates with the Vivado project, which includes its IP cores and settings.
# Vivado records bookkeeping in the .xpr on every launch, so it is restored afterwards.
function sim_project {
	local project=$1 tb=$2 sim_time=$3 sim_dir=$4
	local backup="$sim_dir/project.xpr.backup"
	cp "$project" "$backup"
	trap "cp ${(q)backup} ${(q)project}" EXIT
	trap "cp ${(q)backup} ${(q)project}; exit 130" INT TERM HUP
	rm -f "$build_dir/progress"
	{
		progress_proc
		echo 'report_progress 5 {Opening the project}'
		echo "open_project {$project}"
		if [ -n "$tb" ]
		then
			echo "set_property top {$tb} [get_filesets sim_1]"
		fi
		echo 'set top [get_property top [get_filesets sim_1]]'
		echo '# The launch runs the default time of the project first, so the simulation is restarted'
		echo 'report_progress 15 {Compiling and elaborating}'
		echo 'launch_simulation -simset sim_1 -mode behavioral'
		echo 'restart'
		echo "open_vcd [file join {$sim_dir} \$top.vcd]"
		echo 'log_vcd [get_objects -r *]'
		echo "report_progress 60 {Simulating $sim_time}"
		echo "run $sim_time"
		echo 'close_vcd'
		echo 'close_sim'
		echo 'close_project'
		echo 'report_progress 100 Done'
		echo 'puts "SIMULATION_TOP=$top"'
	} > "$sim_dir/project_sim.tcl"
	local output
	output=$("$xilinx" vivado -mode batch -nojournal -nolog -source "$sim_dir/project_sim.tcl" 2>&1 | tee /dev/stderr)
	local result=$pipestatus[1]
	local top=${${(M)${(f)output}:#SIMULATION_TOP=*}#SIMULATION_TOP=}
	if [[ $result -eq 0 && -n $top ]]
	then
		f_echo "Waveforms written to build/sim/$top.vcd"
	else
		f_echo "Simulation failed. The simulator logs are in the .sim folder of the project."
		exit 1
	fi
}

function cmd_sim {
	local tb=$1 sim_time=${2:-all}
	local sim_dir="$build_dir/sim"
	mkdir -p "$sim_dir"
	local projects=(${(M)${(f)"$(find_files)"}:#*.xpr})
	if (( $#projects > 1 ))
	then
		f_echo "There are several Vivado projects in this folder. Run fpga sim from the folder of one of them."
		exit 1
	elif (( $#projects == 1 ))
	then
		sim_project "${projects[1]}" "$tb" "$sim_time" "$sim_dir"
		return
	fi
	if [ -z "$tb" ]
	then
		usage
	fi
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

# Tcl procedure that prints progress for the terminal and writes it to
# build/progress, which the VS Code extension shows as a progress bar
function progress_proc {
	cat << EOF
proc report_progress {percent message} {
	puts "FPGA_PROGRESS \$percent% \$message"
	set f [open {$build_dir/progress} w]
	puts \$f "\$percent \$message"
	close \$f
}
EOF
}

function cmd_build {
	local top=$1
	mkdir -p "$build_dir"
	rm -f "$build_dir/progress"
	local tcl="$build_dir/build.tcl"
	local projects=(${(M)${(f)"$(find_files)"}:#*.xpr})
	if (( $#projects > 1 ))
	then
		f_echo "There are several Vivado projects in this folder. Run fpga build from the folder of one of them."
		exit 1
	elif (( $#projects == 1 ))
	then
		f_echo "Building the Vivado project ${projects[1]:t}"
		{
			progress_proc
			cat << EOF
open_project {${projects[1]}}
set synth [get_runs synth_1]
set impl [get_runs impl_1]
# Like Generate Bitstream in the GUI, only what is out of date runs again
if {[get_property NEEDS_REFRESH \$synth] || [get_property PROGRESS \$synth] ne "100%"} {
	reset_run \$synth
}
if {[get_property NEEDS_REFRESH \$impl] || [get_property STATUS \$impl] ne "write_bitstream Complete!"} {
	reset_run \$impl
	launch_runs \$impl -to_step write_bitstream -jobs 4
	set steps {
		opt_design {50 Optimizing}
		power_opt_design {55 {Optimizing power}}
		place_design {60 Placing}
		post_place_power_opt_design {72 {Optimizing power}}
		phys_opt_design {75 {Optimizing placement}}
		route_design {80 Routing}
		post_route_phys_opt_design {90 {Optimizing routing}}
		write_bitstream {93 {Writing the bitstream}}
	}
	set last ""
	while {1} {
		# Waits up to 3 seconds, then reports the current step
		if {[catch {wait_on_run -timeout 0.05 \$impl}]} {
			after 3000
		}
		set synth_status [get_property STATUS \$synth]
		set impl_status [get_property STATUS \$impl]
		if {[get_property PROGRESS \$impl] eq "100%" || [regexp -nocase {error|fail|cancel} "\$synth_status \$impl_status"]} {
			break
		}
		if {[get_property PROGRESS \$synth] ne "100%"} {
			set ip_running 0
			foreach ip_run [get_runs -quiet -filter {IS_SYNTHESIS && NAME != synth_1}] {
				if {[regexp {Running} [get_property STATUS \$ip_run]]} {
					set ip_running 1
				}
			}
			if {[regexp {Running synth_design} \$synth_status]} {
				set current {20 Synthesizing}
			} elseif {\$ip_running} {
				set current {5 {Synthesizing IP cores}}
			} else {
				set current {3 {Starting synthesis}}
			}
		} else {
			set current {45 Implementing}
			dict for {step info} \$steps {
				if {[string first "Running \$step" \$impl_status] == 0} {
					set current \$info
				}
			}
		}
		if {\$current ne \$last} {
			report_progress [lindex \$current 0] [lindex \$current 1]
			set last \$current
		}
	}
} else {
	puts "The bitstream is up to date."
}
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
report_progress 100 Done
EOF
		} > "$tcl"
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
			progress_proc
			cat << EOF
report_progress 10 Synthesizing
synth_design -top $top -part $fpga_part
report_progress 50 Optimizing
opt_design
report_progress 60 Placing
place_design
report_progress 80 Routing
route_design
report_utilization -file {$build_dir/utilization.rpt}
report_timing_summary -file {$build_dir/timing.rpt}
report_progress 93 {Writing the bitstream}
write_bitstream -force {$build_dir/$top.bit}
report_progress 100 Done
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

# Writes vhdl_ls.toml for the VHDL LS extension. With Vivado projects, each project
# becomes a library with the VHDL files it uses, so projects that keep their own
# copies of shared files don't clash. Without projects, a generic template is used.
function cmd_vhdl_ls {
	local marker="# Generated by fpga vhdl-ls"
	if [ -f vhdl_ls.toml ] && ! grep -qF -- "$marker" vhdl_ls.toml
	then
		f_echo "vhdl_ls.toml was not generated by fpga, not changing it."
		return
	fi
	local projects=(${(M)${(f)"$(find_files)"}:#*.xpr})
	if (( $#projects == 0 ))
	then
		{ echo "$marker"; cat "$script_dir/templates/vhdl_ls.toml"; } > vhdl_ls.toml
	else
		python3 - "$marker" $projects > vhdl_ls.toml << 'EOF'
import os, re, sys
marker, projects = sys.argv[1], sys.argv[2:]
root = os.getcwd()
print(marker + " from the Vivado projects; run it again after adding files or projects.")
print("# Each project is a library, so work.* refers to the files of the same project.")
print("[libraries]")
for project in sorted(projects):
	project_dir = os.path.dirname(project)
	text = open(project, errors="ignore").read()
	files = []
	for fileset in re.finditer(r'<FileSet Name="(?:sources_1|sim_1)".*?</FileSet>', text, re.S):
		for path in re.findall(r'<File Path="([^"]+\.vhdl?)"', fileset.group(0), re.I):
			path = os.path.normpath(path.replace("$PPRDIR", project_dir))
			if os.path.exists(path) and path not in files:
				files.append(path)
	name = re.sub(r"\W+", "_", os.path.relpath(project_dir, root)).strip("_").lower() or "design"
	if not name[0].isalpha():
		name = "lib_" + name
	relative = ",\n\t".join('"%s"' % os.path.relpath(f, root).replace('"', '\\"') for f in files)
	print(f"\n# {os.path.relpath(project, root)}\n{name}.files = [\n\t{relative},\n]")
EOF
	fi
	f_echo "Wrote vhdl_ls.toml"
}

function cmd_init {
	cmd_vhdl_ls
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
	vhdl-ls) cmd_vhdl_ls "$@" ;;
	*) usage ;;
esac
