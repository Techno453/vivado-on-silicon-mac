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

function expandHome(folder) {
	return path.resolve(folder.replace(/^~(?=$|\/)/, os.homedir()));
}

// The buttons are only shown in the folders listed in fpgaTools.projectFolders (all if empty)
function isEnabled() {
	const allowed = config().get("projectFolders").map(expandHome);
	if (allowed.length === 0) {
		return true;
	}
	return (vscode.workspace.workspaceFolders || []).some((folder) =>
		allowed.some((dir) => folder.uri.fsPath === dir || folder.uri.fsPath.startsWith(dir + path.sep))
	);
}

// The folder to run fpga in: the closest folder with a Vivado project (.xpr) above the
// open file, so each lab of a repository is handled on its own. Files outside of a lab,
// e.g. shared components, ask for the lab and remember it.
async function projectFolder() {
	const workspace = workspaceFolder();
	if (!workspace) {
		return undefined;
	}
	const root = workspace.uri.fsPath;
	const editor = vscode.window.activeTextEditor;
	if (editor && editor.document.uri.scheme === "file") {
		let dir = path.dirname(editor.document.uri.fsPath);
		while (dir.startsWith(root)) {
			if (fs.readdirSync(dir).some((name) => name.endsWith(".xpr"))) {
				return dir;
			}
			if (dir === root) {
				break;
			}
			dir = path.dirname(dir);
		}
	}
	const projects = await vscode.workspace.findFiles(new vscode.RelativePattern(workspace, "**/*.xpr"), EXCLUDE_GLOB);
	if (projects.length === 0) {
		return root;
	}
	if (projects.length === 1) {
		return path.dirname(projects[0].fsPath);
	}
	const last = context.workspaceState.get("project");
	const items = projects
		.map((project) => ({
			label: path.basename(project.fsPath, ".xpr"),
			description: vscode.workspace.asRelativePath(path.dirname(project.fsPath)),
			dir: path.dirname(project.fsPath),
		}))
		.sort((a, b) => (b.dir === last) - (a.dir === last));
	const picked = await vscode.window.showQuickPick(items, { placeHolder: "Which lab?" });
	if (picked) {
		context.workspaceState.update("project", picked.dir);
	}
	return picked && picked.dir;
}

// The simulation top of a Vivado project, read from its .xpr
function projectSimulationTop(dir) {
	const project = fs.readdirSync(dir).find((name) => name.endsWith(".xpr"));
	if (!project) {
		return undefined;
	}
	const xpr = fs.readFileSync(path.join(dir, project), "utf8");
	const match = xpr.match(/<FileSet Name="sim_1"[\s\S]*?<Option Name="TopModule" Val="([^"]+)"/);
	return match && match[1];
}

// Names of the VHDL entities or Verilog modules declared in a file
function designUnits(text) {
	const clean = text.replace(/--.*$/gm, "").replace(/\/\/.*$/gm, "");
	const vhdl = [...clean.matchAll(/^\s*entity\s+(\w+)\s+is\b/gim)].map((m) => m[1]);
	const verilog = [...clean.matchAll(/^\s*module\s+(\w+)/gm)].map((m) => m[1]);
	return vhdl.concat(verilog);
}

async function workspaceUnits(dir) {
	const files = await vscode.workspace.findFiles(new vscode.RelativePattern(dir, HDL_GLOB), EXCLUDE_GLOB);
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
async function runFpga(key, title, args, dir) {
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
		workspaceFolder() || vscode.TaskScope.Workspace,
		title,
		"FPGA",
		new vscode.ShellExecution(fpga, args, { cwd: dir, env }),
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
	const document = uri instanceof vscode.Uri
		? await vscode.workspace.openTextDocument(uri)
		: vscode.window.activeTextEditor && vscode.window.activeTextEditor.document;
	if (uri instanceof vscode.Uri) {
		await vscode.window.showTextDocument(document);
	}
	const dir = await projectFolder();
	if (!dir) {
		return;
	}
	// The testbench is the one in the open file; with a Vivado project, the project's
	// simulation top is used otherwise, and without one, a testbench is picked
	let testbench = "";
	if (document && /\.(vhdl?|s?v)$/i.test(document.fileName)) {
		const units = designUnits(document.getText());
		testbench = units.find(isTestbench) || "";
	}
	const projectTop = projectSimulationTop(dir);
	if (!testbench && !projectTop) {
		const units = (await workspaceUnits(dir)).filter((unit) => isTestbench(unit.name));
		const picked = await vscode.window.showQuickPick(
			units.map((unit) => ({ label: unit.name, description: vscode.workspace.asRelativePath(unit.file) })),
			{ placeHolder: "Testbench to simulate" }
		);
		if (!picked) {
			return;
		}
		testbench = picked.label;
	}
	const name = testbench || projectTop;
	const time = await vscode.window.showInputBox({
		title: `Simulate ${name}`,
		prompt: "Simulation time, e.g. 50us, or all if the testbench stops by itself",
		value: context.workspaceState.get("simTime", "50us"),
	});
	if (!time) {
		return;
	}
	context.workspaceState.update("simTime", time);
	const exitCode = await runFpga("simulate", `Simulate ${name}`, ["sim", testbench, time], dir);
	if (exitCode === 0) {
		const waveform = vscode.Uri.file(path.join(dir, "build", "sim", `${name}.vcd`));
		context.workspaceState.update("lastWaveform", waveform.fsPath);
		vscode.commands.executeCommand("vscode.open", waveform);
	}
}

async function build() {
	const dir = await projectFolder();
	if (!dir) {
		return;
	}
	const args = ["build"];
	if (!fs.readdirSync(dir).some((name) => name.endsWith(".xpr"))) {
		// Without a Vivado project, the top-level unit is picked, the last one first
		const last = context.workspaceState.get("top");
		const units = (await workspaceUnits(dir)).filter((unit) => !isTestbench(unit.name));
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
	const exitCode = await runFpga("build", "Build bitstream", args, dir);
	if (exitCode === 0) {
		const choice = await vscode.window.showInformationMessage("FPGA: The bitstream is ready in build/.", "Program Board");
		if (choice) {
			program();
		}
	}
}

async function program() {
	const dir = await projectFolder();
	if (dir) {
		const exitCode = await runFpga("program", "Program board", ["program"], dir);
		if (exitCode === 0) {
			vscode.window.showInformationMessage("FPGA: The board was programmed.");
		}
	}
}

async function openWaveform() {
	let waveform = context.workspaceState.get("lastWaveform");
	if (!waveform || !fs.existsSync(waveform)) {
		const folder = workspaceFolder();
		const files = folder ? await vscode.workspace.findFiles(new vscode.RelativePattern(folder, "**/build/sim/*.vcd")) : [];
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
		await runFpga("init", "Set up project folder", ["init"], folder.uri.fsPath);
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
	if (container.refreshing || !isEnabled()) {
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

	const containerItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 96);
	containerItem.command = "fpgaTools.toggleContainer";
	statusItems.container = containerItem;
	context.subscriptions.push(containerItem);
	updateContainerItem();
	refreshContainer();

	const updateEnabled = () => {
		const enabled = isEnabled();
		vscode.commands.executeCommand("setContext", "fpgaTools.enabled", enabled);
		for (const item of Object.values(statusItems)) {
			if (enabled) {
				item.show();
			} else {
				item.hide();
			}
		}
	};
	updateEnabled();
	context.subscriptions.push(
		vscode.workspace.onDidChangeWorkspaceFolders(updateEnabled),
		vscode.workspace.onDidChangeConfiguration((event) => {
			if (event.affectsConfiguration("fpgaTools")) {
				updateEnabled();
				updateContainerItem();
			}
		})
	);
	const timer = setInterval(refreshContainer, 15000);
	context.subscriptions.push({ dispose: () => clearInterval(timer) });
}

function deactivate() {}

module.exports = { activate, deactivate };
