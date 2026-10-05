// Buttons, commands and a sidebar for the fpga command of vivado-on-silicon-mac.
// Each action runs bin/fpga as a VS Code task, so errors show up in the Problems panel.

const vscode = require("vscode");
const { execFile } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const HDL_GLOB = "**/*.{vhd,vhdl,v,sv}";
// Vivado's generated copies and build output
const EXCLUDE_GLOB = "**/{build,.Xil,*.sim,*.runs,*.gen,*.cache,*.hw,*.ip_user_files,xsim.dir}/**";

let context;
let running = null;
const statusItems = {};

function config() {
	return vscode.workspace.getConfiguration("fpgaTools");
}

function toolsFolder() {
	return config().get("toolsFolder").replace(/^~(?=$|\/)/, os.homedir());
}

function workspaceFolder() {
	const editor = vscode.window.activeTextEditor;
	const folder = editor && vscode.workspace.getWorkspaceFolder(editor.document.uri);
	return folder || (vscode.workspace.workspaceFolders || [])[0];
}

// Names of the VHDL entities or Verilog modules declared in a file
function designUnits(text) {
	const clean = text.replace(/--.*$/gm, "").replace(/\/\/.*$/gm, "");
	const vhdl = [...clean.matchAll(/^\s*entity\s+(\w+)\s+is\b/gim)].map((m) => m[1]);
	const verilog = [...clean.matchAll(/^\s*module\s+(\w+)/gm)].map((m) => m[1]);
	return vhdl.concat(verilog);
}

async function workspaceUnits(folder) {
	const files = await vscode.workspace.findFiles(new vscode.RelativePattern(folder, HDL_GLOB), EXCLUDE_GLOB);
	const units = [];
	for (const file of files) {
		const text = (await vscode.workspace.fs.readFile(file)).toString();
		for (const name of designUnits(text)) {
			units.push({ name, file });
		}
	}
	return units;
}

function isTestbench(name) {
	return /(^tb_|_tb$|_testbench$|^testbench)/i.test(name);
}

function setBusy(label) {
	const busy = Boolean(label);
	for (const [key, item] of Object.entries(statusItems)) {
		if (!item.idleText) {
			continue;
		}
		item.text = busy && key === label ? `$(sync~spin) ${item.idleText}` : `${item.idleIcon} ${item.idleText}`;
	}
	vscode.commands.executeCommand("setContext", "fpgaTools.busy", busy);
}

// Runs bin/fpga with the given arguments as a task and resolves with its exit code
async function runFpga(key, title, args, folder) {
	if (running) {
		vscode.window.showWarningMessage(`FPGA: wait until "${running}" has finished.`);
		return undefined;
	}
	const fpga = path.join(toolsFolder(), "bin", "fpga");
	if (!fs.existsSync(fpga)) {
		const choice = await vscode.window.showErrorMessage(
			`FPGA: ${fpga} was not found. Set the folder of vivado-on-silicon-mac in the settings.`,
			"Open Settings"
		);
		if (choice) {
			vscode.commands.executeCommand("workbench.action.openSettings", "fpgaTools.toolsFolder");
		}
		return undefined;
	}
	await vscode.workspace.saveAll(false);
	const env = {};
	if (config().get("part")) {
		env.FPGA_PART = config().get("part");
	}
	const task = new vscode.Task(
		{ type: "fpgaTools", action: args[0] },
		folder,
		title,
		"FPGA",
		new vscode.ShellExecution(fpga, args, { cwd: folder.uri.fsPath, env }),
		["$vivado", "$vivado-critical"]
	);
	task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, clear: true };
	running = title;
	setBusy(key);
	try {
		const execution = await vscode.tasks.executeTask(task);
		return await new Promise((resolve) => {
			const listener = vscode.tasks.onDidEndTaskProcess((event) => {
				if (event.execution === execution) {
					listener.dispose();
					resolve(event.exitCode);
				}
			});
		});
	} finally {
		running = null;
		setBusy(null);
		container.lastUsed = Date.now();
		refreshContainer();
	}
}

async function simulate(uri) {
	const folder = workspaceFolder();
	if (!folder) {
		return;
	}
	// The testbench is the unit of the file the button was pressed on or that is open,
	// otherwise one is picked from the workspace
	const document = uri instanceof vscode.Uri
		? await vscode.workspace.openTextDocument(uri)
		: vscode.window.activeTextEditor && vscode.window.activeTextEditor.document;
	let testbench;
	if (document && /\.(vhdl?|s?v)$/i.test(document.fileName)) {
		const units = designUnits(document.getText());
		testbench = units.find(isTestbench) || units[0];
	}
	if (!testbench) {
		const units = (await workspaceUnits(folder)).filter((unit) => isTestbench(unit.name));
		const picked = await vscode.window.showQuickPick(
			units.map((unit) => ({ label: unit.name, description: vscode.workspace.asRelativePath(unit.file) })),
			{ placeHolder: "Testbench to simulate" }
		);
		if (!picked) {
			return;
		}
		testbench = picked.label;
	}
	const time = await vscode.window.showInputBox({
		title: `Simulate ${testbench}`,
		prompt: "Simulation time, e.g. 50us, or all if the testbench stops by itself",
		value: context.workspaceState.get("simTime", "50us"),
	});
	if (!time) {
		return;
	}
	context.workspaceState.update("simTime", time);
	const exitCode = await runFpga("simulate", `Simulate ${testbench}`, ["sim", testbench, time], folder);
	if (exitCode === 0) {
		const waveform = vscode.Uri.file(path.join(folder.uri.fsPath, "build", "sim", `${testbench}.vcd`));
		context.workspaceState.update("lastWaveform", waveform.fsPath);
		vscode.commands.executeCommand("vscode.open", waveform);
	}
}

async function build() {
	const folder = workspaceFolder();
	if (!folder) {
		return;
	}
	const args = ["build"];
	const projects = await vscode.workspace.findFiles(new vscode.RelativePattern(folder, "**/*.xpr"), EXCLUDE_GLOB);
	if (projects.length === 0) {
		// Without a Vivado project, the top-level unit is picked, the last one first
		const last = context.workspaceState.get("top");
		const units = (await workspaceUnits(folder)).filter((unit) => !isTestbench(unit.name));
		units.sort((a, b) => (b.name === last) - (a.name === last));
		const picked = await vscode.window.showQuickPick(
			units.map((unit) => ({ label: unit.name, description: vscode.workspace.asRelativePath(unit.file) })),
			{ placeHolder: "Top-level entity to build" }
		);
		if (!picked) {
			return;
		}
		context.workspaceState.update("top", picked.label);
		args.push(picked.label);
	}
	const exitCode = await runFpga("build", "Build bitstream", args, folder);
	if (exitCode === 0) {
		const choice = await vscode.window.showInformationMessage("FPGA: The bitstream is ready in build/.", "Program Board");
		if (choice) {
			program();
		}
	}
}

async function program() {
	const folder = workspaceFolder();
	if (folder) {
		const exitCode = await runFpga("program", "Program board", ["program"], folder);
		if (exitCode === 0) {
			vscode.window.showInformationMessage("FPGA: The board was programmed.");
		}
	}
}

async function openWaveform() {
	let waveform = context.workspaceState.get("lastWaveform");
	if (!waveform || !fs.existsSync(waveform)) {
		const folder = workspaceFolder();
		const files = folder ? await vscode.workspace.findFiles(new vscode.RelativePattern(folder, "build/sim/*.vcd")) : [];
		if (files.length === 0) {
			vscode.window.showInformationMessage("FPGA: There are no waveforms yet. Simulate a testbench first.");
			return;
		}
		files.sort((a, b) => fs.statSync(b.fsPath).mtimeMs - fs.statSync(a.fsPath).mtimeMs);
		waveform = files[0].fsPath;
	}
	vscode.commands.executeCommand("vscode.open", vscode.Uri.file(waveform));
}

function openGui() {
	const terminal = vscode.window.createTerminal({ name: "Vivado GUI" });
	terminal.show();
	terminal.sendText(`'${path.join(toolsFolder(), "scripts", "start_container.sh")}'`);
}

async function init() {
	const folder = workspaceFolder();
	if (folder) {
		await runFpga("init", "Set up project folder", ["init"], folder);
	}
}

// The container runtime (OrbStack, or Docker Desktop) is only kept running while it is
// used: the fpga command starts it on demand, and it is stopped after some idle minutes.
const container = {
	running: false,
	lastUsed: Date.now(),
	onDidChange: new vscode.EventEmitter(),
};

function findExecutable(...candidates) {
	return candidates.find((candidate) => fs.existsSync(candidate));
}

function orbPath() {
	return findExecutable("/usr/local/bin/orb", "/Applications/OrbStack.app/Contents/MacOS/bin/orb");
}

function dockerPath() {
	return findExecutable("/usr/local/bin/docker", path.join(os.homedir(), ".orbstack/bin/docker"), "/opt/homebrew/bin/docker");
}

function run(command, args) {
	return new Promise((resolve) => {
		execFile(command, args, { timeout: 120000 }, (error, stdout) => resolve({ ok: !error, stdout: stdout || "" }));
	});
}

async function containerIsRunning() {
	const orb = orbPath();
	if (orb) {
		return (await run(orb, ["status"])).stdout.trim() === "Running";
	}
	const docker = dockerPath();
	return Boolean(docker) && (await run(docker, ["info"])).ok;
}

async function runningContainers() {
	const docker = dockerPath();
	const result = docker ? await run(docker, ["ps", "-q"]) : { stdout: "" };
	return result.stdout.split("\n").filter(Boolean).length;
}

async function refreshContainer() {
	if (container.refreshing) {
		return;
	}
	container.refreshing = true;
	try {
		await updateContainerState();
	} finally {
		container.refreshing = false;
	}
}

async function updateContainerState() {
	const wasRunning = container.running;
	container.running = await containerIsRunning();
	if (container.running && (running || (await runningContainers()) > 0)) {
		container.lastUsed = Date.now();
	}
	if (!wasRunning && container.running) {
		// Started by someone else, so the idle time starts now
		container.lastUsed = Date.now();
	}
	const minutes = config().get("autoStopMinutes");
	if (container.running && !running && minutes > 0 && Date.now() - container.lastUsed > minutes * 60000) {
		await stopContainer(true);
		container.running = await containerIsRunning();
	}
	updateContainerItem();
	if (wasRunning !== container.running) {
		container.onDidChange.fire();
	}
}

function updateContainerItem() {
	const item = statusItems.container;
	if (item) {
		item.text = container.running ? "$(vm-running) Container" : "$(vm-outline) Container off";
		const minutes = config().get("autoStopMinutes");
		item.tooltip = container.running
			? `FPGA: The Vivado container is running${minutes > 0 ? ` and stops after ${minutes} idle minutes` : ""}. Click to stop it.`
			: "FPGA: The Vivado container is stopped and starts when needed. Click to start it now.";
	}
}

async function startContainer() {
	const orb = orbPath();
	await vscode.window.withProgress(
		{ location: vscode.ProgressLocation.Window, title: "Starting the Vivado container" },
		() => (orb ? run(orb, ["start"]) : run("/usr/bin/open", ["-a", "Docker"]))
	);
	container.lastUsed = Date.now();
	await refreshContainer();
}

async function stopContainer(automatic) {
	if (running) {
		if (!automatic) {
			vscode.window.showWarningMessage(`FPGA: wait until "${running}" has finished.`);
		}
		return;
	}
	if (!automatic && (await runningContainers()) > 0) {
		const choice = await vscode.window.showWarningMessage(
			"FPGA: A container is still running (e.g. the Vivado GUI). Stopping closes it without saving.",
			{ modal: true },
			"Stop Anyway"
		);
		if (!choice) {
			return;
		}
	}
	const orb = orbPath();
	await vscode.window.withProgress(
		{ location: vscode.ProgressLocation.Window, title: "Stopping the Vivado container" },
		() => (orb ? run(orb, ["stop"]) : run("/usr/bin/osascript", ["-e", 'quit app "Docker Desktop"']))
	);
	if (automatic) {
		vscode.window.setStatusBarMessage("FPGA: Stopped the idle Vivado container", 10000);
	}
	await refreshContainer();
}

function toggleContainer() {
	return container.running ? stopContainer(false) : startContainer();
}

// Sidebar with the same actions as the buttons
class ActionsProvider {
	constructor() {
		this.onDidChangeTreeData = container.onDidChange.event;
	}

	getTreeItem(item) {
		return item;
	}

	getChildren() {
		const actions = [
			["Simulate Testbench", "play", "fpgaTools.simulate", "Simulate the open testbench and show its waveforms (Ctrl+Alt+S)"],
			["Build Bitstream", "tools", "fpgaTools.build", "Synthesize, implement and write the bitstream (Ctrl+Alt+B)"],
			["Program Board", "zap", "fpgaTools.program", "Program the newest bitstream over USB-JTAG (Ctrl+Alt+P)"],
			["Open Last Waveform", "pulse", "fpgaTools.openWaveform", "Open the waveforms of the last simulation"],
			["Open Vivado GUI", "window", "fpgaTools.openGui", "Start the Vivado desktop in Screen Sharing"],
			["Set Up Project Folder", "gear", "fpgaTools.init", "Add a VHDL LS configuration and .gitignore entries"],
			container.running
				? ["Stop Container", "vm-running", "fpgaTools.toggleContainer", "The Vivado container is running. Stop it to save memory and battery."]
				: ["Start Container", "vm-outline", "fpgaTools.toggleContainer", "The Vivado container is stopped. It also starts by itself when needed."],
		];
		return actions.map(([label, icon, command, tooltip]) => {
			const item = new vscode.TreeItem(label);
			item.iconPath = new vscode.ThemeIcon(icon);
			item.command = { command, title: label };
			item.tooltip = tooltip;
			return item;
		});
	}
}

function activate(extensionContext) {
	context = extensionContext;
	const commands = {
		"fpgaTools.simulate": simulate,
		"fpgaTools.build": build,
		"fpgaTools.program": program,
		"fpgaTools.openWaveform": openWaveform,
		"fpgaTools.openGui": openGui,
		"fpgaTools.init": init,
		"fpgaTools.startContainer": startContainer,
		"fpgaTools.stopContainer": () => stopContainer(false),
		"fpgaTools.toggleContainer": toggleContainer,
	};
	for (const [id, handler] of Object.entries(commands)) {
		context.subscriptions.push(vscode.commands.registerCommand(id, handler));
	}
	context.subscriptions.push(vscode.window.registerTreeDataProvider("fpgaTools.actions", new ActionsProvider()));

	const buttons = [
		["simulate", "$(play)", "Simulate", "fpgaTools.simulate", "FPGA: Simulate the open testbench (Ctrl+Alt+S)"],
		["build", "$(tools)", "Build", "fpgaTools.build", "FPGA: Build the bitstream (Ctrl+Alt+B)"],
		["program", "$(zap)", "Program", "fpgaTools.program", "FPGA: Program the board (Ctrl+Alt+P)"],
	];
	buttons.forEach(([key, icon, text, command, tooltip], index) => {
		const item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100 - index);
		item.idleIcon = icon;
		item.idleText = text;
		item.command = command;
		item.tooltip = tooltip;
		statusItems[key] = item;
		context.subscriptions.push(item);
	});
	setBusy(null);
	for (const item of Object.values(statusItems)) {
		item.show();
	}

	const containerItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 96);
	containerItem.command = "fpgaTools.toggleContainer";
	statusItems.container = containerItem;
	context.subscriptions.push(containerItem);
	updateContainerItem();
	containerItem.show();
	refreshContainer();
	const timer = setInterval(refreshContainer, 15000);
	context.subscriptions.push({ dispose: () => clearInterval(timer) });
}

function deactivate() {}

module.exports = { activate, deactivate };
