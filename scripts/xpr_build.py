#!/usr/bin/env python3

# Writes a Tcl script that builds the bitstream of a Vivado project (.xpr) in a single
# Vivado process (non-project mode), reading the sources, constraints and IP cores from
# the project. Project mode starts a separate Vivado for each IP core, synthesis and
# implementation, which costs a lot of time and memory under Rosetta.
#
# The IP cores are copied to <build>/ip and synthesized there once, so the project's
# folders are not touched. A copy is only resynthesized when its .xci changes.
#
# Usage: xpr_build.py <project.xpr> <build folder>
# Prints the path of the Tcl script, or exits with 2 if the project uses something this
# flow does not handle (e.g. block designs), so that the caller can use project mode.

import json
import os
import re
import shutil
import sys

project, build_dir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
project_dir = os.path.dirname(project)
name = os.path.splitext(os.path.basename(project))[0]
text = open(project, errors="ignore").read()


def resolve(path):
	path = path.replace("$PPRDIR", project_dir)
	path = path.replace("$PSRCDIR", os.path.join(project_dir, name + ".srcs"))
	return os.path.normpath(path)


def filesets(type_name):
	return re.finditer(r'<FileSet Name="([^"]+)" Type="%s".*?</FileSet>' % type_name, text, re.S)


def files(fileset_text):
	result = []
	for match in re.finditer(r'<File Path="([^"]+)">(.*?)</File>', fileset_text, re.S):
		result.append((resolve(match.group(1)), match.group(2)))
	return result


def option(fileset_text, option_name):
	match = re.search(r'<Option Name="%s" Val="([^"]*)"' % option_name, fileset_text)
	return match and match.group(1)


def tcl_list(paths):
	return "[list %s]" % " ".join("{%s}" % path for path in paths)


sources = next(filesets("DesignSrcs"), None)
constraints = next(filesets("Constrs"), None)
if not sources:
	sys.exit(2)
source_files = files(sources.group(0))
# Block designs (e.g. for the Zynq processor) and other generated sources need project mode
if any(path.endswith((".bd", ".xcix", ".edf", ".edif", ".dcp")) for path, _ in source_files):
	sys.exit(2)

part = re.search(r'<Option Name="Part" Val="([^"]+)"', text).group(1)
top = option(sources.group(0), "TopModule")
vhdl, vhdl2008, verilog, systemverilog = [], [], [], []
for path, info in source_files:
	lower = path.lower()
	if lower.endswith((".vhd", ".vhdl")):
		(vhdl2008 if 'Val="VHDL 2008"' in info else vhdl).append(path)
	elif lower.endswith(".sv"):
		systemverilog.append(path)
	elif lower.endswith(".v"):
		verilog.append(path)

# Constraints used only for implementation are read after synthesis
synth_xdc, impl_xdc = [], []
if constraints:
	for path, info in files(constraints.group(0)):
		if path.endswith(".xdc"):
			(impl_xdc if 'Val="synthesis"' not in info and "UsedIn" in info else synth_xdc).append(path)

# IP cores: listed in the sources, or after a build in a fileset of their own
xcis = [path for path, _ in source_files if path.endswith(".xci")]
for match in filesets("BlockSrcs"):
	xcis += [path for path, _ in files(match.group(0)) if path.endswith(".xci") and path not in xcis]
ip_copies = []
for xci in xcis:
	ip = os.path.splitext(os.path.basename(xci))[0]
	ip_dir = os.path.join(build_dir, "ip", ip)
	original = os.path.join(ip_dir, ip + ".xci.original")
	copy = os.path.join(ip_dir, ip + ".xci")
	content = open(xci, "rb").read()
	if not os.path.exists(original) or open(original, "rb").read() != content:
		shutil.rmtree(ip_dir, ignore_errors=True)
		os.makedirs(ip_dir)
		open(original, "wb").write(content)
		# The generated files of the copy go next to it, not into the project's .gen folder
		try:
			data = json.loads(content)
			data["ip_inst"]["gen_directory"] = "."
			runtime = data["ip_inst"].get("parameters", {}).get("runtime_parameters", {})
			if "OUTPUTDIR" in runtime:
				runtime["OUTPUTDIR"] = [{"value": "."}]
			open(copy, "w").write(json.dumps(data, indent=2))
		except ValueError:
			# Older XML format
			xml = content.decode(errors="ignore")
			xml = re.sub(r'(spirit:id="RUNTIME_PARAM\.OUTPUTDIR">)[^<]*', r"\1.", xml)
			open(copy, "w").write(xml)
	ip_copies.append(copy)

repo = re.search(r'<Option Name="IPRepoPath" Val="([^"]+)"', text)

tcl = []
tcl.append(f"create_project -in_memory -part {part}")
tcl.append("set_property target_language VHDL [current_project]")
if repo:
	tcl.append(f"set_property ip_repo_paths [list {{{resolve(repo.group(1))}}}] [current_project]")
	tcl.append("update_ip_catalog -quiet")
if ip_copies:
	tcl.append(f"read_ip {tcl_list(ip_copies)}")
	tcl.append("""set ips_to_synthesize {}
foreach ip [get_ips] {
	if {![file exists [file rootname [get_property IP_FILE $ip]].dcp]} {
		lappend ips_to_synthesize $ip
	}
}
if {[llength $ips_to_synthesize]} {
	report_progress 3 {Synthesizing IP cores}
	foreach ip $ips_to_synthesize {
		generate_target all $ip
		synth_ip $ip
	}
}""")
if vhdl:
	tcl.append(f"read_vhdl -library xil_defaultlib {tcl_list(vhdl)}")
if vhdl2008:
	tcl.append(f"read_vhdl -vhdl2008 -library xil_defaultlib {tcl_list(vhdl2008)}")
if verilog:
	tcl.append(f"read_verilog {tcl_list(verilog)}")
if systemverilog:
	tcl.append(f"read_verilog -sv {tcl_list(systemverilog)}")
if synth_xdc:
	tcl.append(f"read_xdc {tcl_list(synth_xdc)}")
tcl.append("report_progress 8 Synthesizing")
tcl.append(f"synth_design -top {top} -part {part}")
if impl_xdc:
	tcl.append(f"read_xdc {tcl_list(impl_xdc)}")
# Rough share of the build time at which each step starts, measured on Lab 2
tcl.append("report_progress 45 Optimizing\nopt_design")
tcl.append("report_progress 57 Placing\nplace_design")
tcl.append("report_progress 62 Routing\nroute_design")
tcl.append(f"report_utilization -file {{{build_dir}/utilization.rpt}}")
tcl.append(f"report_timing_summary -no_detailed_paths -file {{{build_dir}/timing.rpt}}")
tcl.append("""set slack [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
if {$slack ne "" && $slack < 0} {
	puts "CRITICAL WARNING: \\[Timing 38-282\\] The design does not meet timing: worst negative slack $slack ns, see build/timing.rpt"
} else {
	puts "Timing is met (worst slack $slack ns)."
}""")
tcl.append("report_progress 75 {Writing the bitstream}")
tcl.append(f"write_bitstream -force {{{build_dir}/{top}.bit}}")
tcl.append("report_progress 100 Done")

script = os.path.join(build_dir, "fast_build.tcl")
open(script, "w").write("\n".join(tcl) + "\n")
print(script)
