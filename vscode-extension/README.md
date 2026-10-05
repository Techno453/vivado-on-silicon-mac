# FPGA Tools

Buttons for the `fpga` command of [vivado-on-silicon-mac](https://github.com/Techno453/vivado-on-silicon-mac), which runs Vivado 2024.2 in a container on Apple Silicon Macs.

- **Status bar:** Simulate, Build and Program buttons, and the state of the container
- **Editor title:** a run button on VHDL and Verilog files that simulates the testbench in the file and opens its waveforms
- **FPGA sidebar:** all actions, including the Vivado GUI and starting or stopping the container
- **Shortcuts:** Ctrl+Alt+S simulate, Ctrl+Alt+B build, Ctrl+Alt+P program

The buttons only appear in the folders listed in `fpgaTools.projectFolders` (by default `~/Desktop/Code Work/AdvDigitalDesign`). In a repository with several labs, each action uses the lab folder with the Vivado project (.xpr) that contains the open file; for files outside of a lab, it asks for the lab. Simulations of Vivado projects use the project's sources, IP cores and testbench.

Errors from Vivado appear in the Problems panel and link to the source line. The container starts when an action needs it and is stopped after `fpgaTools.autoStopMinutes` idle minutes (default 10).

Waveforms open in the [Surfer](https://marketplace.visualstudio.com/items?itemName=surfer-project.surfer) extension if it is installed.

Build the extension with `python3 build_vsix.py` and install it with `code --install-extension fpga-tools-<version>.vsix`.
