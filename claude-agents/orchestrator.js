const fs = require('fs').promises;
const path = require('path');
const { spawn } = require('child_process');

class LocalClaudeOrchestrator {
    constructor() {
        this.baseDir = process.cwd();
        this.sharedDir = path.join(this.baseDir, 'shared');
        this.worktrees = new Map();
        this.activeWorkflows = new Map();
        this.simulators = new Map();
        this.projectRoot = path.join(this.baseDir, '..');
    }

    async initialize() {
        console.log('🤖 Initializing Claude Multi-Agent System...');
        
        // Ensure directories exist
        await this.ensureDirectories();
        
        // Discover simulators
        await this.discoverSimulators();
        
        // Setup file watchers
        this.setupTaskWatcher();
        
        console.log('✅ Orchestrator ready');
        console.log(`📂 Working directory: ${this.baseDir}`);
        console.log(`📁 Project root: ${this.projectRoot}`);
    }

    async ensureDirectories() {
        try {
            await fs.mkdir(this.sharedDir, { recursive: true });
            await fs.mkdir(path.join(this.sharedDir, 'tasks'), { recursive: true });
            await fs.mkdir(path.join(this.sharedDir, 'results'), { recursive: true });
            await fs.mkdir(path.join(this.baseDir, 'worktrees'), { recursive: true });
            console.log('📁 Created necessary directories');
        } catch (error) {
            console.log('📁 Directories already exist or created');
        }
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
        this.processedTasks = new Set();
        
        // Simple polling approach since chokidar might not be available
        setInterval(async () => {
            try {
                const files = await fs.readdir(taskDir);
                for (const file of files) {
                    if (file.endsWith('.json') && !this.processedTasks.has(file)) {
                        this.processedTasks.add(file);
                        await this.handleNewTask(path.join(taskDir, file));
                    }
                }
            } catch (error) {
                // Tasks directory might not exist yet
            }
        }, 2000);
    }

    async handleNewTask(taskFile) {
        try {
            const taskData = await fs.readFile(taskFile, 'utf8');
            const task = JSON.parse(taskData);
            
            console.log(`📋 New task: ${task.id} (${task.type})`);
            
            if (task.type === 'ios-feature-workflow') {
                await this.executeIOSFeatureWorkflow(task);
            } else if (task.type === 'test-orchestrator') {
                await this.executeTestWorkflow(task);
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
            repoPath: this.projectRoot,
            status: 'running',
            startTime: new Date()
        };
        
        this.activeWorkflows.set(workflowId, workflow);
        
        try {
            // Create single worktree for all phases
            const agentId = `${workflowId}-agent`;
            const worktreePath = await this.createWorktree(agentId, this.projectRoot);
            
            // Execute comprehensive task
            await this.runClaudeInWorktree(agentId, worktreePath, {
                type: 'ios-comprehensive',
                prompt: `You are working on a Catbird iOS app issue in a dedicated git worktree.

TASK: ${task.feature.name}
DESCRIPTION: ${task.feature.description}

REQUIREMENTS:
${task.feature.requirements.map(req => `- ${req}`).join('\n')}

YOUR MISSION (execute all phases):

PHASE 1 - ANALYSIS:
1. Examine the current ThemeManager.swift implementation
2. Identify why navigation bars stay black in dim mode
3. Check the current theme application logic
4. Document your findings

PHASE 2 - IMPLEMENTATION:
1. Fix the navigation bar color issue
2. Ensure dim gray (rgb(46, 46, 50)) is used in dim mode
3. Test that theme changes update immediately
4. Verify no regressions in other modes

PHASE 3 - TESTING:
1. Build the app for iOS simulator
2. Test theme switching between light, dark, and dim modes
3. Verify navigation bar colors update correctly
4. Take screenshots showing the fix working
5. Test on multiple screens to ensure consistency

PHASE 4 - DOCUMENTATION:
1. Document the changes made
2. Explain the root cause and solution
3. Create summary of testing results

IMPORTANT:
- Work in this dedicated worktree: ${worktreePath}
- Make incremental commits with clear messages
- Save results to ${this.sharedDir}/results/${workflowId}-results.json
- Include screenshots in ${this.sharedDir}/results/${workflowId}-screenshots/

Begin your comprehensive analysis and implementation now!`
            });
            
            workflow.status = 'completed';
            workflow.endTime = new Date();
            
            console.log(`✅ iOS feature workflow completed: ${workflowId}`);
            
        } catch (error) {
            workflow.status = 'failed';
            workflow.error = error.message;
            console.error(`❌ Workflow ${workflowId} failed:`, error.message);
        }
    }

    async executeTestWorkflow(task) {
        console.log(`🧪 Executing test workflow: ${task.id}`);
        
        try {
            // Create a simple test to verify the orchestrator works
            const testResultsPath = path.join(this.sharedDir, 'results', `test-${Date.now()}.json`);
            
            const testResults = {
                testId: task.id,
                timestamp: new Date().toISOString(),
                orchestratorStatus: 'working',
                cliBinaryFound: await this.checkClaudeCLI(),
                simulatorAccess: this.simulators.size > 0,
                projectAccess: await this.checkProjectAccess(),
                worktreeSupport: await this.checkWorktreeSupport()
            };
            
            await fs.writeFile(testResultsPath, JSON.stringify(testResults, null, 2));
            console.log(`✅ Test workflow completed. Results saved to: ${testResultsPath}`);
            
        } catch (error) {
            console.error(`❌ Test workflow failed:`, error.message);
        }
    }

    async assignTaskToAgent(task) {
        console.log(`📋 Assigning generic task: ${task.id}`);
        
        try {
            // For now, just create a simple agent worktree
            const agentId = `generic-${Date.now()}`;
            const worktreePath = await this.createWorktree(agentId, this.projectRoot);
            
            await this.runClaudeInWorktree(agentId, worktreePath, {
                type: 'generic',
                prompt: task.description || `Complete task: ${task.id}`
            });
            
        } catch (error) {
            console.error(`❌ Failed to assign task ${task.id}:`, error.message);
        }
    }

    async checkClaudeCLI() {
        try {
            await this.exec('which claude');
            return true;
        } catch {
            return false;
        }
    }

    async checkProjectAccess() {
        try {
            await fs.access(path.join(this.projectRoot, 'Catbird.xcodeproj'));
            return true;
        } catch {
            return false;
        }
    }

    async checkWorktreeSupport() {
        try {
            await this.exec('git worktree list', { cwd: this.projectRoot });
            return true;
        } catch {
            return false;
        }
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
- Project root: ${this.projectRoot}
- Results directory: ${this.sharedDir}/results

## Catbird Project Context
This is the Catbird iOS app - a native Bluesky client built with SwiftUI. 

Key files you'll likely need:
- Core/State/ThemeManager.swift (theme management)
- Core/UI/ThemeColors.swift (color definitions)
- App/ContentView.swift (main app structure)
- Features/Profile/Views/HomeView.swift (navigation structure)

## iOS Development Guidelines
- Use SwiftUI for UI components
- Follow iOS Human Interface Guidelines
- Implement proper error handling
- Use modern Swift concurrency (async/await)
- Follow the existing code patterns in the project
- Test on iOS simulator to verify fixes
- Ensure accessibility support

## Completion Criteria
When you finish this task:
1. Commit your changes with descriptive messages
2. Save detailed results to the shared results directory
3. Include screenshots showing the fix working
4. Document the root cause and solution

Begin your work now!
`;

        await fs.writeFile(path.join(worktreePath, 'CLAUDE.md'), claudeMd);
        
        // Run Claude Code CLI in the worktree using only the command line tool
        return new Promise((resolve, reject) => {
            console.log(`🚀 Starting Claude Code session for agent ${agentId}`);
            console.log(`📂 Working directory: ${worktreePath}`);
            
            // Use claude CLI with the task prompt
            const claude = spawn('claude', [
                'Please read the CLAUDE.md file in this directory and complete the comprehensive iOS theme fix task described in it. Work systematically through each phase and document your progress.'
            ], {
                cwd: worktreePath,
                stdio: ['pipe', 'pipe', 'pipe']
            });
            
            let output = '';
            let error = '';
            
            claude.stdout.on('data', (data) => {
                const chunk = data.toString();
                output += chunk;
                process.stdout.write(`[${agentId}] ${chunk}`);
            });
            
            claude.stderr.on('data', (data) => {
                const chunk = data.toString();
                error += chunk;
                process.stderr.write(`[${agentId}] ERROR: ${chunk}`);
            });
            
            claude.on('close', (code) => {
                if (code === 0) {
                    console.log(`✅ Agent ${agentId} completed successfully`);
                    resolve(output);
                } else {
                    console.error(`❌ Agent ${agentId} failed with exit code ${code}`);
                    console.error(`Error output: ${error}`);
                    reject(new Error(`Claude CLI failed with code ${code}: ${error}`));
                }
            });
            
            claude.on('error', (err) => {
                console.error(`❌ Failed to spawn Claude CLI for agent ${agentId}:`, err.message);
                reject(err);
            });
        });
    }


    async exec(command, options = {}) {
        return new Promise((resolve, reject) => {
            require('child_process').exec(command, options, (error, stdout, stderr) => {
                if (error) reject(error);
                else resolve({ stdout, stderr });
            });
        });
    }

}

// Start the orchestrator
const orchestrator = new LocalClaudeOrchestrator();
orchestrator.initialize().catch(console.error);

console.log('🔍 Watching for tasks in shared/tasks/');
console.log('📝 Add a JSON task file to start a workflow');

// Keep the process running
process.on('SIGINT', () => {
    console.log('\n👋 Shutting down orchestrator...');
    process.exit(0);
});
