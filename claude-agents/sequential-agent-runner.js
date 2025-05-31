#!/usr/bin/env node

/**
 * Sequential Agent Runner for Catbird Development
 * 
 * This runs one feature agent at a time to avoid CLI interface conflicts.
 * Each agent completes its work before the next one starts.
 */

const fs = require('fs');
const path = require('path');
const { spawn, execSync } = require('child_process');

const SHARED_DIR = path.join(__dirname, 'shared');
const TASKS_DIR = path.join(SHARED_DIR, 'tasks');
const RESULTS_DIR = path.join(SHARED_DIR, 'results');
const WORKTREES_DIR = path.join(__dirname, 'worktrees');

// Ensure directories exist
[SHARED_DIR, TASKS_DIR, RESULTS_DIR, WORKTREES_DIR].forEach(dir => {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
});

class SequentialAgentRunner {
  constructor() {
    this.processedTasks = new Set();
    this.currentAgent = null;
    this.taskQueue = [];
  }

  async initialize() {
    console.log('🤖 Initializing Sequential Agent Runner...');
    console.log('📁 Project root:', path.resolve(__dirname, '..'));
    
    // Check for Claude CLI
    try {
      execSync('which claude', { stdio: 'ignore' });
      console.log('✅ Claude CLI found');
    } catch (error) {
      console.error('❌ Claude CLI not found. Please install: npm install -g @anthropic-ai/claude-code');
      process.exit(1);
    }

    // Load existing tasks
    this.loadTasks();
    
    console.log(`📋 Found ${this.taskQueue.length} tasks to process`);
    
    // Start processing
    this.startProcessing();
  }

  loadTasks() {
    try {
      const taskFiles = fs.readdirSync(TASKS_DIR);
      
      for (const file of taskFiles) {
        if (file.endsWith('.json')) {
          try {
            const taskPath = path.join(TASKS_DIR, file);
            const task = JSON.parse(fs.readFileSync(taskPath, 'utf8'));
            
            if (!this.processedTasks.has(task.id)) {
              this.taskQueue.push({ ...task, file });
            }
          } catch (error) {
            console.error(`❌ Error loading task ${file}:`, error.message);
          }
        }
      }
      
      // Sort by priority (higher number = higher priority)
      this.taskQueue.sort((a, b) => (b.priority || 0) - (a.priority || 0));
      
    } catch (error) {
      console.error('❌ Error loading tasks:', error.message);
    }
  }

  async startProcessing() {
    if (this.taskQueue.length === 0) {
      console.log('📝 No tasks to process. Add JSON files to shared/tasks/ to start workflows.');
      console.log('👀 Watching for new tasks...');
      this.watchForTasks();
      return;
    }

    console.log('🚀 Starting sequential task processing...');
    
    for (const task of this.taskQueue) {
      await this.processTask(task);
    }
    
    console.log('✅ All tasks completed!');
    console.log('👀 Watching for new tasks...');
    this.watchForTasks();
  }

  async processTask(task) {
    if (this.processedTasks.has(task.id)) {
      return;
    }

    console.log(`\n📋 Processing task: ${task.id}`);
    console.log(`🎯 Feature: ${task.feature?.name || 'Unknown'}`);
    
    try {
      const workflowId = `workflow-${Date.now()}`;
      const agentId = `${workflowId}-agent`;
      
      // Create worktree for this agent
      const worktreePath = await this.createWorktree(agentId, task);
      
      // Run Claude CLI agent
      const result = await this.runClaudeAgent(agentId, worktreePath, task);
      
      // Save results
      await this.saveResults(task.id, result);
      
      // Mark as processed
      this.processedTasks.add(task.id);
      
      console.log(`✅ Completed task: ${task.id}`);
      
    } catch (error) {
      console.error(`❌ Error processing task ${task.id}:`, error.message);
      
      // Save error result
      await this.saveResults(task.id, {
        success: false,
        error: error.message,
        timestamp: new Date().toISOString()
      });
    }
  }

  async createWorktree(agentId, task) {
    const worktreePath = path.join(WORKTREES_DIR, agentId);
    const projectRoot = path.resolve(__dirname, '..');
    
    try {
      // Create new branch and worktree
      const branchName = `agent/${agentId}`;
      
      execSync(`git worktree add -b ${branchName} ${worktreePath} main`, {
        cwd: projectRoot,
        stdio: 'inherit'
      });
      
      console.log(`📁 Created worktree: ${worktreePath}`);
      return worktreePath;
      
    } catch (error) {
      throw new Error(`Failed to create worktree: ${error.message}`);
    }
  }

  async runClaudeAgent(agentId, worktreePath, task) {
    return new Promise((resolve, reject) => {
      console.log(`🚀 Starting Claude Code session for ${agentId}`);
      
      // Create comprehensive instructions for the agent
      const instructions = this.generateAgentInstructions(task);
      
      // Run Claude CLI in the worktree
      const claudeProcess = spawn('claude', [], {
        cwd: worktreePath,
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env, ANTHROPIC_MODEL: 'claude-3-5-sonnet-20241022' }
      });

      let output = '';
      let errorOutput = '';

      claudeProcess.stdout.on('data', (data) => {
        const text = data.toString();
        output += text;
        console.log(`[${agentId}] ${text.trim()}`);
      });

      claudeProcess.stderr.on('data', (data) => {
        const text = data.toString();
        errorOutput += text;
        console.error(`[${agentId}] ERROR: ${text.trim()}`);
      });

      claudeProcess.on('close', (code) => {
        if (code === 0) {
          resolve({
            success: true,
            output,
            agentId,
            worktreePath,
            timestamp: new Date().toISOString()
          });
        } else {
          reject(new Error(`Claude process exited with code ${code}. Error: ${errorOutput}`));
        }
      });

      claudeProcess.on('error', (error) => {
        reject(new Error(`Failed to start Claude process: ${error.message}`));
      });

      // Send instructions to Claude
      claudeProcess.stdin.write(instructions);
      claudeProcess.stdin.end();
    });
  }

  generateAgentInstructions(task) {
    const feature = task.feature || {};
    
    return `I am a specialized iOS development agent working on the Catbird app (a native Bluesky client).

CURRENT TASK: ${task.id}
FEATURE: ${feature.name || 'Unknown Feature'}
DESCRIPTION: ${feature.description || 'No description provided'}

WORKING DIRECTORY: This is a git worktree dedicated to this feature.
REQUIREMENTS:
${(feature.requirements || []).map(req => `- ${req}`).join('\n')}

KEY FILES TO REVIEW:
${(feature.key_files || []).map(file => `- ${file}`).join('\n')}

TESTING CRITERIA:
${(feature.testing_criteria || []).map(criteria => `- ${criteria}`).join('\n')}

WORKFLOW:
1. Analyze the current implementation in the key files
2. Implement the required improvements
3. Test using iOS simulator (${task.simulator || 'iPhone 16 Pro'})
4. Take screenshots to verify fixes work
5. Commit changes with descriptive commit messages
6. Provide a summary of work completed

IMPORTANT:
- Use SwiftUI best practices
- Follow iOS Human Interface Guidelines  
- Test thoroughly on iOS simulator
- Commit incrementally with clear messages
- Document any issues or blockers

Please start by analyzing the current state and then implementing the requirements.

When you're done, type "AGENT_COMPLETE" to signal completion.
`;
  }

  async saveResults(taskId, result) {
    const resultsFile = path.join(RESULTS_DIR, `${taskId}-${Date.now()}.json`);
    
    try {
      fs.writeFileSync(resultsFile, JSON.stringify(result, null, 2));
      console.log(`💾 Results saved: ${resultsFile}`);
    } catch (error) {
      console.error('❌ Error saving results:', error.message);
    }
  }

  watchForTasks() {
    fs.watchFile(TASKS_DIR, { interval: 5000 }, () => {
      console.log('👀 Checking for new tasks...');
      this.loadTasks();
      
      if (this.taskQueue.length > 0 && !this.currentAgent) {
        this.startProcessing();
      }
    });
  }
}

// Start the agent runner
const runner = new SequentialAgentRunner();
runner.initialize().catch(console.error);