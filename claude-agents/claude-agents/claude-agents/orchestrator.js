const fs = require('fs').promises;
const path = require('path');
const { spawn } = require('child_process');
const chokidar = require('chokidar');

class LocalClaudeOrchestrator {
    constructor() {
        this.baseDir = process.cwd();
        this.sharedDir = path.join(this.baseDir, 'shared');
        this.agents = new Map();
        this.worktrees = new Map();
        this.activeWorkflows = new Map();
        this.simulators = new Map();
    }

    async initialize() {
        console.log('🤖 Initializing Claude Multi-Agent System...');
        
        // Setup file watchers
        this.setupTaskWatcher();
        this.setupResultWatcher();
        
        // Discover iOS simulators
        await this.discoverSimulators();
        
        console.log('✅ Orchestrator ready');
        console.log(`📂 Working directory: ${this.baseDir}`);
        console.log(`📁 Shared directory: ${this.sharedDir}`);
    }

    async discoverSimulators() {
        if (process.platform !== 'darwin') return;
        
        try {
            const { stdout } = await this.exec('xcrun simctl list devices --json');
            const devices = JSON.parse(stdout);
            
            Object.entries(devices.devices).forEach(([runtime, deviceList]) => {
                if (runtime.includes('iOS')) {
                    deviceList.forEach(device => {
                        if (device.state === 'Booted' || device.isAvailable) {
                            this.simulators.set(device.udid, {
                                name: device.name,
                                runtime: runtime,
                                udid: device.udid,
                                state: device.state
                            });
                        }
                    });
                }
            });
            
            console.log(`📱 Found ${this.simulators.size} available iOS simulators`);
        } catch (error) {
            console.log('ℹ️  iOS simulator discovery failed (not on macOS?)');
        }
    }

    setupTaskWatcher() {
        const taskDir = path.join(this.sharedDir, 'tasks');
        const watcher = chokidar.watch(taskDir, { ignored: /^\./, persistent: true });
        
        watcher.on('add', async (filePath) => {
            if (filePath.endsWith('.json')) {
                await this.handleNewTask(filePath);
            }
        });
    }

    async handleNewTask(taskFile) {
        try {
            const taskData = await fs.readFile(taskFile, 'utf8');
            const task = JSON.parse(taskData);
            
            console.log(`📋 New task: ${task.id} (${task.type})`);
            
            if (task.type === 'ios-feature-workflow') {
                await this.executeIOSFeatureWorkflow(task);
            } else {
                await this.assignTaskToAgent(task);
            }
            
            // Clean up task file
            await fs.unlink(taskFile);
        } catch (error) {
            console.error(`❌ Error processing task ${taskFile}:`, error.message);
        }
    }

    async executeIOSFeatureWorkflow(task) {
        const workflowId = `workflow-${Date.now()}`;
        console.log(`🚀 Starting iOS feature workflow: ${workflowId}`);
        
        const workflow = {
            id: workflowId,
            feature: task.feature,
            repoPath: task.repoPath,
            status: 'running',
            phases: {
                analysis: { status: 'pending', agent: null },
                implementation: { status: 'pending', agent: null },
                testing: { status: 'pending', agent: null },
                review: { status: 'pending', agent: null }
            },
            startTime: new Date(),
            simulator: null
        };
        
        this.activeWorkflows.set(workflowId, workflow);
        
        try {
            // Phase 1: Feature Analysis
            await this.executePhase(workflow, 'analysis', {
                type: 'feature-analysis',
                prompt: `Analyze this iOS feature request and create an implementation plan:

Feature: ${task.feature.name}
Description: ${task.feature.description}
Requirements: ${task.feature.requirements?.join(', ')}

Please:
1. Break down the feature into specific tasks
2. Identify the files that need to be modified
3. Plan the implementation approach
4. Suggest test scenarios
5. Create a timeline estimate

Output your analysis to shared/results/${workflowId}-analysis.json`
            });
            
            // Phase 2: Implementation
            await this.executePhase(workflow, 'implementation', {
                type: 'ios-implementation',
                prompt: `Implement the iOS feature based on the analysis.

Workflow ID: ${workflowId}
Check shared/results/${workflowId}-analysis.json for the implementation plan.

Your tasks:
1. Read the analysis and understand the requirements
2. Create/modify the necessary Swift/SwiftUI files
3. Follow iOS development best practices
4. Ensure code compiles and follows project conventions
5. Commit your changes with descriptive messages

Work in your dedicated git worktree and implement the feature completely.`
            });
            
            // Phase 3: iOS Simulator Testing
            const simulator = Array.from(this.simulators.values())[0];
            if (simulator) {
                workflow.simulator = simulator.udid;
                await this.executePhase(workflow, 'testing', {
                    type: 'ios-testing',
                    prompt: `Test the implemented iOS feature using the simulator.

Workflow ID: ${workflowId}
Simulator: ${simulator.name} (${simulator.udid})

Your tasks:
1. Build the iOS app for the simulator
2. Install and launch the app
3. Test the new feature thoroughly
4. Take screenshots of the feature working
5. Test edge cases and error scenarios
6. Document any issues found
7. Create automated UI tests if possible

Save test results to shared/results/${workflowId}-testing.json
Include screenshots in shared/results/${workflowId}-screenshots/`
                });
            }
            
            // Phase 4: Code Review
            await this.executePhase(workflow, 'review', {
                type: 'code-review',
                prompt: `Review the implemented iOS feature code.

Workflow ID: ${workflowId}
Review the implementation and testing results.

Your tasks:
1. Review code quality and iOS best practices
2. Check for potential bugs or issues
3. Verify test coverage
4. Suggest improvements
5. Ensure the feature meets requirements
6. Approve or request changes

Output your review to shared/results/${workflowId}-review.json`
            });
            
            workflow.status = 'completed';
            workflow.endTime = new Date();
            
            console.log(`✅ iOS feature workflow completed: ${workflowId}`);
            await this.generateWorkflowSummary(workflow);
            
        } catch (error) {
            workflow.status = 'failed';
            workflow.error = error.message;
            console.error(`❌ Workflow ${workflowId} failed:`, error.message);
        }
    }

    async executePhase(workflow, phaseName, task) {
        console.log(`🔄 Phase: ${phaseName}`);
        workflow.phases[phaseName].status = 'running';
        
        // Create worktree for this phase
        const agentId = `${workflow.id}-${phaseName}`;
        const worktreePath = await this.createWorktree(agentId, workflow.repoPath);
        
        workflow.phases[phaseName].agent = agentId;
        workflow.phases[phaseName].worktree = worktreePath;
        
        // Execute task with Claude
        await this.runClaudeInWorktree(agentId, worktreePath, task);
        
        workflow.phases[phaseName].status = 'completed';
        console.log(`✅ Phase completed: ${phaseName}`);
    }

    async createWorktree(agentId, repoPath) {
        const worktreePath = path.join(this.baseDir, 'worktrees', agentId);
        const branchName = `agent/${agentId}`;
        
        try {
            // Create git worktree
            await this.exec(`git worktree add -b ${branchName} ${worktreePath} main`, { cwd: repoPath });
            
            this.worktrees.set(agentId, {
                path: worktreePath,
                branch: branchName,
                repoPath: repoPath,
                created: new Date()
            });
            
            console.log(`📁 Created worktree: ${worktreePath}`);
            return worktreePath;
        } catch (error) {
            console.error(`❌ Failed to create worktree for ${agentId}:`, error.message);
            throw error;
        }
    }

    async runClaudeInWorktree(agentId, worktreePath, task) {
        // Create CLAUDE.md with task instructions
        const claudeMd = `# Agent: ${agentId}
Task Type: ${task.type}

## Your Mission
${task.prompt}

## Working Environment
- Worktree: ${worktreePath}
- Shared results: ${this.sharedDir}/results
- Coordination: ${this.sharedDir}/coordination

## iOS Development Guidelines
${task.type.includes('ios') ? `
- Use SwiftUI for UI components
- Follow iOS Human Interface Guidelines
- Implement proper error handling
- Use modern Swift concurrency (async/await)
- Follow the existing code patterns in the project
- Test on the provided iOS simulator
- Ensure accessibility support
` : ''}

## Completion Criteria
When you finish this task:
1. Commit your changes with a descriptive message
2. Save any results/analysis to the shared results directory
3. Update the coordination file with your status

## Available Tools
You have access to all standard tools including:
- File operations (Edit, Create, Read)
- Terminal commands (Bash)
- Git operations
- iOS development tools (if applicable)

Begin your work now!
`;

        await fs.writeFile(path.join(worktreePath, 'CLAUDE.md'), claudeMd);
        
        // Run Claude Code in the worktree
        return new Promise((resolve, reject) => {
            const claude = spawn('claude', ['-p', `Please read the CLAUDE.md file and complete the assigned task.`], {
                cwd: worktreePath,
                stdio: ['inherit', 'pipe', 'pipe']
            });
            
            let output = '';
            let error = '';
            
            claude.stdout.on('data', (data) => {
                output += data.toString();
                process.stdout.write(`[${agentId}] ${data}`);
            });
            
            claude.stderr.on('data', (data) => {
                error += data.toString();
                process.stderr.write(`[${agentId}] ${data}`);
            });
            
            claude.on('close', (code) => {
                if (code === 0) {
                    console.log(`✅ Agent ${agentId} completed successfully`);
                    resolve(output);
                } else {
                    console.error(`❌ Agent ${agentId} failed with code ${code}`);
                    reject(new Error(`Agent failed: ${error}`));
                }
            });
        });
    }

    async generateWorkflowSummary(workflow) {
        const summary = {
            workflowId: workflow.id,
            feature: workflow.feature,
            status: workflow.status,
            duration: workflow.endTime - workflow.startTime,
            phases: workflow.phases,
            simulator: workflow.simulator,
            results: {
                analysis: await this.readResultFile(`${workflow.id}-analysis.json`),
                implementation: await this.getImplementationSummary(workflow),
                testing: await this.readResultFile(`${workflow.id}-testing.json`),
                review: await this.readResultFile(`${workflow.id}-review.json`)
            }
        };
        
        await fs.writeFile(
            path.join(this.sharedDir, 'results', `${workflow.id}-summary.json`),
            JSON.stringify(summary, null, 2)
        );
        
        console.log(`📊 Workflow summary saved: ${workflow.id}-summary.json`);
    }

    async readResultFile(filename) {
        try {
            const content = await fs.readFile(
                path.join(this.sharedDir, 'results', filename),
                'utf8'
            );
            return JSON.parse(content);
        } catch {
            return null;
        }
    }

    async getImplementationSummary(workflow) {
        const implPhase = workflow.phases.implementation;
        if (!implPhase.worktree) return null;
        
        try {
            const { stdout } = await this.exec('git log --oneline -10', { cwd: implPhase.worktree });
            const { stdout: diff } = await this.exec('git diff main --stat', { cwd: implPhase.worktree });
            
            return {
                commits: stdout.split('\n').filter(line => line.trim()),
                changes: diff
            };
        } catch {
            return null;
        }
    }

    async exec(command, options = {}) {
        return new Promise((resolve, reject) => {
            require('child_process').exec(command, options, (error, stdout, stderr) => {
                if (error) reject(error);
                else resolve({ stdout, stderr });
            });
        });
    }

    setupResultWatcher() {
        // Monitor for completed workflows
        const resultsDir = path.join(this.sharedDir, 'results');
        const watcher = chokidar.watch(resultsDir, { ignored: /^\./, persistent: true });
        
        watcher.on('add', async (filePath) => {
            if (filePath.endsWith('-summary.json')) {
                console.log(`📋 Workflow completed: ${path.basename(filePath)}`);
            }
        });
    }
}

// Start the orchestrator
const orchestrator = new LocalClaudeOrchestrator();
orchestrator.initialize().catch(console.error);

// Keep the process running
process.on('SIGINT', () => {
    console.log('\n👋 Shutting down orchestrator...');
    process.exit(0);
});
