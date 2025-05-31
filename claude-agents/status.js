const fs = require('fs').promises;
const path = require('path');

async function checkStatus() {
    console.log('📊 Claude Multi-Agent System Status\n');
    
    // Check worktrees
    try {
        const worktrees = await fs.readdir('worktrees');
        console.log(`📁 Active worktrees: ${worktrees.length}`);
        worktrees.forEach(wt => console.log(`   - ${wt}`));
    } catch {
        console.log('📁 No active worktrees');
    }
    
    console.log();
    
    // Check recent results
    try {
        const results = await fs.readdir('shared/results');
        const recent = results.filter(f => f.endsWith('.json')).slice(-5);
        console.log(`📋 Recent results (${results.length} total):`);
        recent.forEach(r => console.log(`   - ${r}`));
    } catch {
        console.log('📋 No results yet');
    }
    
    console.log();
    
    // Check for running tmux session
    try {
        const { exec } = require('child_process');
        exec('tmux list-sessions | grep claude-agents', (error, stdout) => {
            if (stdout.trim()) {
                console.log('🟢 Claude agents session is running');
                console.log('   Use: tmux attach -t claude-agents');
            } else {
                console.log('🔴 Claude agents session not found');
                console.log('   Start with: npm run agents');
            }
        });
    } catch {
        console.log('❓ Cannot check tmux status');
    }
}

checkStatus().catch(console.error);
