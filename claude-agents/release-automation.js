#!/usr/bin/env node

/**
 * Catbird Release Automation Script
 * Deploys multiple Claude agents in parallel to fix all release blockers
 */

const { exec } = require('child_process');
const { promisify } = require('util');
const fs = require('fs').promises;
const path = require('path');

const execAsync = promisify(exec);

// Define all release tasks with proper model assignment
const RELEASE_TASKS = [
  // Critical Path - Opus
  {
    id: 'feed-filtering-fix',
    priority: 10,
    model: 'opus',
    description: 'Fix feed filtering implementation',
    prompt: `Fix the feed filtering in Catbird:
1. Implement hideRepliesByUnfollowed in FeedTuner.swift line 473-476
2. Ensure all content filtering settings in ContentMediaSettingsView actually affect feed display
3. Test that all filter combinations work correctly
4. The filtering logic is partially there but needs completion`,
    files: ['Catbird/Features/Feed/Services/FeedTuner.swift', 'Catbird/Features/Settings/Views/ContentMediaSettingsView.swift']
  },
  {
    id: 'language-filtering',
    priority: 10,
    model: 'opus',
    description: 'Implement language filtering',
    prompt: `Implement language filtering in Catbird:
1. Uncomment and implement language filtering in ContentMediaSettingsView.swift lines 82-95
2. Add language detection to PostParser using LanguageDetector utility
3. Filter posts based on user's language preferences in FeedTuner
4. Test with multiple languages`,
    files: ['Catbird/Features/Settings/Views/ContentMediaSettingsView.swift', 'Catbird/Features/Feed/Services/FeedTuner.swift']
  },

  // High Priority - Sonnet
  {
    id: 'font-accessibility',
    priority: 9,
    model: 'sonnet',
    description: 'Verify font accessibility settings',
    prompt: `Verify and complete font accessibility settings:
1. Check that line spacing, display scale, increased contrast, and bold text in AccessibilitySettingsView actually affect text rendering
2. These settings exist in the UI but may not be connected to the rendering system
3. Look at Typography.swift and ensure all settings are applied
4. Test with Dynamic Type at all sizes`,
    files: ['Catbird/Features/Settings/Views/AccessibilitySettingsView.swift', 'Catbird/Core/Extensions/Typography.swift']
  },
  {
    id: 'app-passwords',
    priority: 8,
    model: 'sonnet',
    description: 'Implement app passwords',
    prompt: `Replace "App Passwords functionality coming soon" placeholder:
1. In PrivacySecuritySettingsView.swift line 94, implement actual app passwords
2. Add UI for creating/revoking app-specific passwords
3. Store securely in Keychain
4. Use ATProtoClient for API calls`,
    files: ['Catbird/Features/Settings/Views/PrivacySecuritySettingsView.swift']
  },
  {
    id: 'moderation-lists',
    priority: 8,
    model: 'sonnet',
    description: 'Implement moderation lists',
    prompt: `Replace "Moderation Lists feature coming soon" in ModerationSettingsView.swift:
1. Implement UI for managing moderation lists
2. Add create/subscribe/unsubscribe functionality
3. Use ATProtoClient for moderation list API calls
4. Show current subscriptions`,
    files: ['Catbird/Features/Settings/Views/ModerationSettingsView.swift']
  },
  {
    id: 'typing-indicators',
    priority: 7,
    model: 'sonnet',
    description: 'Fix typing indicators',
    prompt: `Fix typing indicators in ChatManager.swift:
1. Replace simulated typing (lines 1668-1672) with real AT Protocol events
2. Implement sendTypingIndicator and receiveTypingIndicator
3. Use WebSocket or polling for real-time updates
4. Test across multiple devices`,
    files: ['Catbird/Features/Chat/Services/ChatManager.swift']
  },
  {
    id: 'feed-discovery',
    priority: 7,
    model: 'sonnet',
    description: 'Replace feed discovery placeholders',
    prompt: `Replace hardcoded discovery data:
1. In FeedDiscoveryCardsView.swift, replace placeholder data with real API calls
2. Fetch trending topics and popular feeds from AT Protocol
3. Update SmartFeedRecommendationEngine to use real data
4. Remove all "Demo" and placeholder strings`,
    files: ['Catbird/Features/Feed/Views/FeedDiscoveryCardsView.swift', 'Catbird/Features/Feed/Services/SmartFeedRecommendationEngine.swift']
  },
  {
    id: 'quote-posts',
    priority: 6,
    model: 'sonnet',
    description: 'Complete quote post handling',
    prompt: `Complete quote post TODOs in PostManager.swift:
1. Implement proper quote post creation
2. Handle quote post rendering in PostEmbed.swift
3. Ensure interactions work correctly
4. Test with nested quotes`,
    files: ['Catbird/Features/Feed/Services/PostManager.swift', 'Catbird/Features/Feed/Views/Components/PostEmbed.swift']
  },
  {
    id: 'video-upload',
    priority: 6,
    model: 'sonnet',
    description: 'Add video upload progress',
    prompt: `Improve video upload in MediaUploadManager.swift:
1. Add progress indicators for video uploads
2. Implement video compression options
3. Show upload progress in UI
4. Handle upload cancellation`,
    files: ['Catbird/Features/Feed/Views/Components/PostComposer/Media/MediaUploadManager.swift']
  }
];

// Execute Claude command with proper escaping and verbose output
async function executeClaudeTask(task, workdir) {
  // Add --verbose flag to see what Claude is doing
  const command = `claude -p "${task.prompt.replace(/"/g, '\\"')}" --model ${task.model} --max-turns 10 --verbose`;
  
  console.log(`\n🚀 Starting ${task.id} with ${task.model}...`);
  console.log(`📁 Working on files: ${task.files.join(', ')}`);
  console.log(`📝 Task: ${task.description}\n`);
  
  // Create a log file for this specific task
  const logFile = path.join(__dirname, 'logs', `${task.id}_${Date.now()}.log`);
  await fs.mkdir(path.dirname(logFile), { recursive: true });
  
  try {
    // Use spawn for real-time output
    const { spawn } = require('child_process');
    const child = spawn('claude', [
      '-p', task.prompt,
      '--model', task.model,
      '--max-turns', '10',
      '--verbose'
    ], { 
      cwd: workdir,
      shell: true
    });
    
    let output = '';
    
    // Stream stdout
    child.stdout.on('data', (data) => {
      const text = data.toString();
      output += text;
      // Show abbreviated progress
      if (text.includes('Reading') || text.includes('Writing') || text.includes('Editing')) {
        process.stdout.write(`  📍 ${task.id}: ${text.trim().substring(0, 80)}...\n`);
      }
    });
    
    // Stream stderr
    child.stderr.on('data', (data) => {
      console.error(`  ⚠️  ${task.id}: ${data.toString().trim()}`);
    });
    
    // Wait for completion
    return new Promise((resolve) => {
      child.on('close', (code) => {
        if (code === 0) {
          console.log(`\n✅ ${task.id} completed successfully`);
          resolve({ task: task.id, success: true, output });
        } else {
          console.error(`\n❌ ${task.id} failed with exit code ${code}`);
          resolve({ task: task.id, success: false, error: `Exit code ${code}` });
        }
      });
    });
    
  } catch (error) {
    console.error(`❌ ${task.id} failed:`, error.message);
    return { task: task.id, success: false, error: error.message };
  }
}

// Execute tasks in parallel batches
async function executeBatch(tasks, workdir, batchSize = 3) {
  const results = [];
  
  for (let i = 0; i < tasks.length; i += batchSize) {
    const batch = tasks.slice(i, i + batchSize);
    console.log(`\n📦 Executing batch ${Math.floor(i/batchSize) + 1}/${Math.ceil(tasks.length/batchSize)}`);
    
    const batchResults = await Promise.all(
      batch.map(task => executeClaudeTask(task, workdir))
    );
    
    results.push(...batchResults);
    
    // Brief pause between batches to avoid overwhelming the system
    if (i + batchSize < tasks.length) {
      console.log('⏸️  Pausing between batches...');
      await new Promise(resolve => setTimeout(resolve, 5000));
    }
  }
  
  return results;
}

// Create task files for the orchestrator
async function createTaskFiles(tasks) {
  const tasksDir = path.join(__dirname, 'shared', 'tasks');
  await fs.mkdir(tasksDir, { recursive: true });
  
  for (const task of tasks) {
    const taskFile = {
      id: task.id,
      type: 'ios-feature-workflow',
      priority: task.priority,
      model: task.model,
      description: task.description,
      prompt: task.prompt,
      targetFiles: task.files,
      createdAt: new Date().toISOString()
    };
    
    await fs.writeFile(
      path.join(tasksDir, `${task.id}.json`),
      JSON.stringify(taskFile, null, 2)
    );
  }
}

// Main execution
async function main() {
  console.log('🚀 Catbird Release Automation Starting...\n');
  
  const args = process.argv.slice(2);
  const useOrchestrator = args.includes('--orchestrator');
  const batchSize = parseInt(args.find(a => a.startsWith('--batch-size='))?.split('=')[1] || '3');
  
  if (useOrchestrator) {
    // Create task files for the orchestrator
    console.log('📝 Creating task files for orchestrator...');
    await createTaskFiles(RELEASE_TASKS);
    console.log('✅ Task files created in shared/tasks/');
    console.log('\nNow run: node orchestrator.js');
  } else {
    // Direct execution using Claude CLI
    const workdir = path.resolve(__dirname, '..');
    
    // Sort tasks by priority
    const sortedTasks = RELEASE_TASKS.sort((a, b) => b.priority - a.priority);
    
    // Group by priority for better batching
    const criticalTasks = sortedTasks.filter(t => t.priority >= 10);
    const highPriorityTasks = sortedTasks.filter(t => t.priority >= 7 && t.priority < 10);
    const mediumPriorityTasks = sortedTasks.filter(t => t.priority < 7);
    
    console.log(`📊 Task Distribution:
    - Critical (Opus): ${criticalTasks.length} tasks
    - High Priority (Sonnet): ${highPriorityTasks.length} tasks  
    - Medium Priority (Sonnet): ${mediumPriorityTasks.length} tasks
    - Batch Size: ${batchSize}\n`);
    
    // Execute critical tasks first (smaller batch size for Opus)
    console.log('🔴 Phase 1: Critical Tasks (Opus)');
    const criticalResults = await executeBatch(criticalTasks, workdir, 2);
    
    // Execute high priority tasks
    console.log('\n🟡 Phase 2: High Priority Tasks (Sonnet)');
    const highResults = await executeBatch(highPriorityTasks, workdir, batchSize);
    
    // Execute medium priority tasks if requested
    if (args.includes('--all')) {
      console.log('\n🟢 Phase 3: Medium Priority Tasks (Sonnet)');
      const mediumResults = await executeBatch(mediumPriorityTasks, workdir, batchSize);
    }
    
    // Summary
    console.log('\n📈 Execution Summary:');
    const allResults = [...criticalResults, ...highResults];
    const successful = allResults.filter(r => r.success).length;
    const failed = allResults.filter(r => !r.success).length;
    
    console.log(`✅ Successful: ${successful}`);
    console.log(`❌ Failed: ${failed}`);
    
    if (failed > 0) {
      console.log('\nFailed tasks:');
      allResults.filter(r => !r.success).forEach(r => {
        console.log(`- ${r.task}: ${r.error}`);
      });
    }
  }
}

// Run with error handling
main().catch(error => {
  console.error('❌ Fatal error:', error);
  process.exit(1);
});