#!/usr/bin/env python3
"""
Advanced headless task runner for GitHub Copilot CLI
Supports JSON/YAML task definitions, parallel execution, and result aggregation
"""

import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    import yaml
    YAML_SUPPORT = True
except ImportError:
    YAML_SUPPORT = False


class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    MAGENTA = '\033[0;35m'
    CYAN = '\033[0;36m'
    NC = '\033[0m'  # No Color


class CopilotTask:
    """Represents a single Copilot CLI task"""
    
    def __init__(self, name: str, prompt: str, approval: str = "--allow-all-tools",
                 timeout: int = 120, description: str = ""):
        self.name = name
        self.prompt = prompt
        self.approval = approval
        self.timeout = timeout
        self.description = description or prompt
        
    def to_dict(self) -> Dict:
        return {
            "name": self.name,
            "prompt": self.prompt,
            "approval": self.approval,
            "timeout": self.timeout,
            "description": self.description
        }


class TaskRunner:
    """Manages execution of Copilot CLI tasks"""
    
    def __init__(self, results_dir: Path, verbose: bool = False):
        self.results_dir = results_dir
        self.verbose = verbose
        self.timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.log_file = results_dir / f"run_{self.timestamp}.log"
        
        # Create results directory
        self.results_dir.mkdir(parents=True, exist_ok=True)
        
    def log(self, message: str, color: str = Colors.NC):
        """Log message to both console and file"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_msg = f"[{timestamp}] {message}"
        colored_msg = f"{color}{log_msg}{Colors.NC}"
        
        print(colored_msg)
        with open(self.log_file, 'a') as f:
            f.write(log_msg + '\n')
    
    def run_task(self, task: CopilotTask) -> Tuple[bool, str, str]:
        """Execute a single task and return (success, stdout, stderr)"""
        task_log = self.results_dir / f"task_{task.name}_{self.timestamp}.log"
        
        self.log(f"Starting task: {task.name}", Colors.BLUE)
        if self.verbose:
            self.log(f"  Prompt: {task.prompt}", Colors.CYAN)
            self.log(f"  Approval: {task.approval}", Colors.CYAN)
        
        # Build command
        cmd = ["copilot", "-p", task.prompt]
        
        # Parse approval flags
        approval_parts = task.approval.split()
        cmd.extend(approval_parts)
        
        try:
            # Run copilot command
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=task.timeout
            )
            
            # Save output to task log
            with open(task_log, 'w') as f:
                f.write(f"Task: {task.name}\n")
                f.write(f"Prompt: {task.prompt}\n")
                f.write(f"Timestamp: {datetime.now().isoformat()}\n")
                f.write(f"Exit Code: {result.returncode}\n")
                f.write("\n=== STDOUT ===\n")
                f.write(result.stdout)
                f.write("\n=== STDERR ===\n")
                f.write(result.stderr)
            
            success = result.returncode == 0
            
            if success:
                self.log(f"✓ Task '{task.name}' completed successfully", Colors.GREEN)
            else:
                self.log(f"✗ Task '{task.name}' failed (exit code {result.returncode})", Colors.RED)
            
            if self.verbose:
                self.log(f"  Log saved to: {task_log}", Colors.CYAN)
            
            return (success, result.stdout, result.stderr)
            
        except subprocess.TimeoutExpired:
            error_msg = f"Task timed out after {task.timeout} seconds"
            self.log(f"✗ Task '{task.name}' timed out", Colors.RED)
            
            with open(task_log, 'w') as f:
                f.write(f"Task: {task.name}\n")
                f.write(f"Error: {error_msg}\n")
            
            return (False, "", error_msg)
        
        except Exception as e:
            error_msg = str(e)
            self.log(f"✗ Task '{task.name}' error: {error_msg}", Colors.RED)
            
            with open(task_log, 'w') as f:
                f.write(f"Task: {task.name}\n")
                f.write(f"Exception: {error_msg}\n")
            
            return (False, "", error_msg)
    
    def run_parallel(self, tasks: List[CopilotTask], max_workers: int = 4) -> Dict[str, bool]:
        """Run multiple tasks in parallel"""
        self.log(f"Running {len(tasks)} tasks in parallel (max {max_workers} workers)...", Colors.BLUE)
        
        results = {}
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            # Submit all tasks
            future_to_task = {executor.submit(self.run_task, task): task for task in tasks}
            
            # Collect results
            for future in as_completed(future_to_task):
                task = future_to_task[future]
                try:
                    success, stdout, stderr = future.result()
                    results[task.name] = success
                except Exception as e:
                    self.log(f"Task '{task.name}' raised exception: {e}", Colors.RED)
                    results[task.name] = False
        
        # Summary
        successes = sum(1 for v in results.values() if v)
        failures = len(results) - successes
        
        if failures == 0:
            self.log(f"All {len(tasks)} parallel tasks completed successfully", Colors.GREEN)
        else:
            self.log(f"{successes} succeeded, {failures} failed", Colors.YELLOW)
        
        return results
    
    def run_sequential(self, tasks: List[CopilotTask], stop_on_failure: bool = False) -> Dict[str, bool]:
        """Run tasks sequentially"""
        self.log(f"Running {len(tasks)} tasks sequentially...", Colors.BLUE)
        
        results = {}
        for task in tasks:
            success, stdout, stderr = self.run_task(task)
            results[task.name] = success
            
            if not success and stop_on_failure:
                self.log(f"Stopping due to task failure: {task.name}", Colors.YELLOW)
                break
        
        # Summary
        successes = sum(1 for v in results.values() if v)
        failures = len(results) - successes
        
        if failures == 0:
            self.log(f"All {len(tasks)} sequential tasks completed successfully", Colors.GREEN)
        else:
            self.log(f"{successes} succeeded, {failures} failed", Colors.YELLOW)
        
        return results


def load_tasks_from_file(filepath: Path) -> Tuple[Dict[str, CopilotTask], Dict[str, Dict]]:
    """Load tasks and workflows from JSON or YAML file"""
    with open(filepath, 'r') as f:
        if filepath.suffix in ['.yaml', '.yml']:
            if not YAML_SUPPORT:
                raise ImportError("PyYAML required for YAML support. Install with: pip install pyyaml")
            data = yaml.safe_load(f)
        else:
            data = json.load(f)
    
    # Parse tasks
    tasks = {}
    for task_id, task_data in data.get('tasks', {}).items():
        tasks[task_id] = CopilotTask(
            name=task_data.get('name', task_id),
            prompt=task_data['prompt'],
            approval=task_data.get('approval', '--allow-all-tools'),
            timeout=task_data.get('timeout', 120),
            description=task_data.get('description', '')
        )
    
    # Parse workflows
    workflows = data.get('workflows', {})
    
    return tasks, workflows


def main():
    parser = argparse.ArgumentParser(
        description="Advanced headless task runner for GitHub Copilot CLI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run single task
  %(prog)s single "Check Swift syntax" "Check all Swift files for errors" --approval "--allow-tool 'shell(swift)'"
  
  # Run tasks from file in parallel
  %(prog)s from-file copilot-tasks.json --workflow full-build
  
  # Run specific tasks in sequence
  %(prog)s from-file tasks.json --tasks syntax-check build-ios run-tests --sequential
        """
    )
    
    subparsers = parser.add_subparsers(dest='command', help='Command to run')
    
    # Single task command
    single = subparsers.add_parser('single', help='Run a single task')
    single.add_argument('name', help='Task name')
    single.add_argument('prompt', help='Task prompt')
    single.add_argument('--approval', default='--allow-all-tools', help='Approval flags')
    single.add_argument('--timeout', type=int, default=120, help='Task timeout in seconds')
    
    # From-file command
    from_file = subparsers.add_parser('from-file', help='Run tasks from JSON/YAML file')
    from_file.add_argument('file', type=Path, help='Task definition file')
    from_file.add_argument('--workflow', help='Workflow name to run')
    from_file.add_argument('--tasks', nargs='+', help='Specific task IDs to run')
    from_file.add_argument('--sequential', action='store_true', help='Run in sequence')
    from_file.add_argument('--stop-on-failure', action='store_true', help='Stop if task fails')
    from_file.add_argument('--max-workers', type=int, default=4, help='Max parallel workers')
    
    # Global options
    parser.add_argument('-d', '--results-dir', type=Path, default=Path('./copilot-results'),
                       help='Results directory')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output')
    parser.add_argument('--model', help='Copilot model (set COPILOT_MODEL env var)')
    
    args = parser.parse_args()
    
    # Set model if specified
    if args.model:
        os.environ['COPILOT_MODEL'] = args.model
    
    # Check if copilot is installed
    if subprocess.run(['which', 'copilot'], capture_output=True).returncode != 0:
        print(f"{Colors.RED}Error: GitHub Copilot CLI is not installed{Colors.NC}")
        print(f"{Colors.YELLOW}Install it with: gh extension install github/gh-copilot{Colors.NC}")
        sys.exit(1)
    
    # Create task runner
    runner = TaskRunner(args.results_dir, args.verbose)
    runner.log("=== Copilot Task Runner Started ===", Colors.GREEN)
    
    try:
        if args.command == 'single':
            task = CopilotTask(args.name, args.prompt, args.approval, args.timeout)
            success, _, _ = runner.run_task(task)
            sys.exit(0 if success else 1)
        
        elif args.command == 'from-file':
            tasks, workflows = load_tasks_from_file(args.file)
            
            # Determine which tasks to run
            if args.workflow:
                if args.workflow not in workflows:
                    runner.log(f"Workflow '{args.workflow}' not found", Colors.RED)
                    sys.exit(1)
                
                workflow = workflows[args.workflow]
                task_list = [tasks[tid] for tid in workflow['tasks'] if tid in tasks]
                mode = workflow.get('mode', 'sequential')
                
                runner.log(f"Running workflow: {args.workflow}", Colors.MAGENTA)
                runner.log(f"  Description: {workflow.get('description', 'N/A')}", Colors.CYAN)
                
            elif args.tasks:
                task_list = [tasks[tid] for tid in args.tasks if tid in tasks]
                mode = 'sequential' if args.sequential else 'parallel'
            else:
                task_list = list(tasks.values())
                mode = 'sequential' if args.sequential else 'parallel'
            
            # Execute tasks
            if mode == 'sequential':
                results = runner.run_sequential(task_list, args.stop_on_failure)
            else:
                results = runner.run_parallel(task_list, args.max_workers)
            
            # Exit with failure if any task failed
            sys.exit(0 if all(results.values()) else 1)
        
        else:
            parser.print_help()
            sys.exit(1)
    
    finally:
        runner.log("=== Task Runner Finished ===", Colors.GREEN)
        runner.log(f"Results directory: {args.results_dir}", Colors.BLUE)


if __name__ == '__main__':
    main()
