#!/usr/bin/env python3
"""
Experimental parallel agent system for GitHub Copilot CLI
Spawns multiple independent Copilot sessions working on different tasks simultaneously
"""

import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple


class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    MAGENTA = '\033[0;35m'
    CYAN = '\033[0;36m'
    NC = '\033[0m'


class Agent:
    """Represents an independent Copilot agent"""
    
    def __init__(self, agent_id: int, name: str, task: str, approval: str, workspace: Path):
        self.agent_id = agent_id
        self.name = name
        self.task = task
        self.approval = approval
        self.workspace = workspace
        self.log_file = workspace / f"agent_{agent_id}_{name}.log"
        self.status = "pending"
        self.start_time = None
        self.end_time = None
        self.output = ""
        
    def run(self) -> Tuple[bool, str]:
        """Execute the agent's task"""
        self.status = "running"
        self.start_time = time.time()
        
        # Build command
        cmd = [
            "copilot",
            "-p", self.task,
            "--allow-all-paths",  # Required for headless operation
        ]
        
        # Parse approval flags - handle both simple and complex formats
        if self.approval:
            # If it's a simple flag like --allow-all-tools, just add it
            if self.approval.startswith("--"):
                cmd.append(self.approval)
            else:
                # Otherwise split and add each part
                cmd.extend(self.approval.split())
        
        try:
            # Run in workspace directory with stdin redirected to /dev/null
            # This prevents copilot from waiting for interactive input
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,  # Prevent waiting for stdin
                timeout=900,  # 15 minute timeout for complex code generation
                cwd=self.workspace
            )
            
            self.end_time = time.time()
            self.output = result.stdout
            
            # Save log
            with open(self.log_file, 'w') as f:
                f.write(f"Agent: {self.name} (ID: {self.agent_id})\n")
                f.write(f"Task: {self.task}\n")
                f.write(f"Start: {datetime.fromtimestamp(self.start_time).isoformat()}\n")
                f.write(f"End: {datetime.fromtimestamp(self.end_time).isoformat()}\n")
                f.write(f"Duration: {self.end_time - self.start_time:.2f}s\n")
                f.write(f"Exit Code: {result.returncode}\n")
                f.write("\n=== OUTPUT ===\n")
                f.write(result.stdout)
                if result.stderr:
                    f.write("\n=== ERRORS ===\n")
                    f.write(result.stderr)
            
            success = result.returncode == 0
            self.status = "completed" if success else "failed"
            return (success, result.stdout)
            
        except subprocess.TimeoutExpired:
            self.end_time = time.time()
            self.status = "timeout"
            error_msg = "Task timed out"
            
            with open(self.log_file, 'w') as f:
                f.write(f"Agent: {self.name} (ID: {self.agent_id})\n")
                f.write(f"Status: TIMEOUT\n")
            
            return (False, error_msg)
            
        except Exception as e:
            self.end_time = time.time()
            self.status = "error"
            error_msg = str(e)
            
            with open(self.log_file, 'w') as f:
                f.write(f"Agent: {self.name} (ID: {self.agent_id})\n")
                f.write(f"Error: {error_msg}\n")
            
            return (False, error_msg)
    
    def duration(self) -> float:
        """Get execution duration in seconds"""
        if self.start_time and self.end_time:
            return self.end_time - self.start_time
        return 0.0


class AgentSwarm:
    """Manages a swarm of parallel agents"""
    
    def __init__(self, workspace: Path, max_agents: int = 4):
        self.workspace = workspace
        self.max_agents = max_agents
        self.agents: List[Agent] = []
        self.timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.results_dir = workspace / "parallel-agents-results" / self.timestamp
        self.results_dir.mkdir(parents=True, exist_ok=True)
        
    def log(self, message: str, color: str = Colors.NC):
        """Log to console with color"""
        timestamp = datetime.now().strftime("%H:%M:%S")
        print(f"{color}[{timestamp}] {message}{Colors.NC}")
    
    def spawn_agent(self, name: str, task: str, approval: str = "--allow-all-tools") -> Agent:
        """Create a new agent"""
        agent = Agent(
            agent_id=len(self.agents),
            name=name,
            task=task,
            approval=approval,
            workspace=self.workspace
        )
        self.agents.append(agent)
        return agent
    
    def execute(self) -> Dict[str, bool]:
        """Execute all agents in parallel"""
        if not self.agents:
            self.log("No agents to execute", Colors.YELLOW)
            return {}
        
        self.log(f"Launching {len(self.agents)} parallel agents (max {self.max_agents} concurrent)", Colors.BLUE)
        
        results = {}
        with ThreadPoolExecutor(max_workers=self.max_agents) as executor:
            # Submit all agents
            future_to_agent = {executor.submit(agent.run): agent for agent in self.agents}
            
            # Track completion
            for future in as_completed(future_to_agent):
                agent = future_to_agent[future]
                try:
                    success, output = future.result()
                    results[agent.name] = success
                    
                    status_color = Colors.GREEN if success else Colors.RED
                    status_symbol = "✓" if success else "✗"
                    self.log(
                        f"{status_symbol} Agent '{agent.name}' {agent.status} ({agent.duration():.1f}s)",
                        status_color
                    )
                    
                except Exception as e:
                    self.log(f"Agent '{agent.name}' raised exception: {e}", Colors.RED)
                    results[agent.name] = False
        
        # Generate summary
        self._generate_summary(results)
        return results
    
    def _generate_summary(self, results: Dict[str, bool]):
        """Generate execution summary"""
        successes = sum(1 for v in results.values() if v)
        failures = len(results) - successes
        
        summary_file = self.results_dir / "summary.json"
        summary = {
            "timestamp": self.timestamp,
            "total_agents": len(self.agents),
            "successful": successes,
            "failed": failures,
            "agents": [
                {
                    "id": agent.agent_id,
                    "name": agent.name,
                    "task": agent.task,
                    "status": agent.status,
                    "duration": agent.duration(),
                    "log_file": str(agent.log_file)
                }
                for agent in self.agents
            ]
        }
        
        with open(summary_file, 'w') as f:
            json.dump(summary, f, indent=2)
        
        self.log("", Colors.NC)
        self.log("=== SUMMARY ===", Colors.CYAN)
        self.log(f"Total agents: {len(self.agents)}", Colors.NC)
        self.log(f"Successful: {successes}", Colors.GREEN)
        self.log(f"Failed: {failures}", Colors.RED if failures > 0 else Colors.NC)
        self.log(f"Summary: {summary_file}", Colors.CYAN)
        self.log(f"Logs: {self.results_dir}", Colors.CYAN)


def load_agent_config(config_file: Path) -> List[Dict]:
    """Load agent configuration from JSON file"""
    with open(config_file, 'r') as f:
        data = json.load(f)
    return data.get('agents', [])


def main():
    parser = argparse.ArgumentParser(
        description="Experimental parallel agent system for GitHub Copilot CLI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Quick spawn 3 agents
  %(prog)s quick "Check syntax" "Run tests" "Update docs"
  
  # Load from config file
  %(prog)s from-config agents.json
  
  # Interactive mode
  %(prog)s interactive
        """
    )
    
    subparsers = parser.add_subparsers(dest='command', help='Command to run')
    
    # Quick mode - spawn agents from CLI args
    quick = subparsers.add_parser('quick', help='Quick spawn agents from command line')
    quick.add_argument('tasks', nargs='+', help='Agent tasks')
    quick.add_argument('--approval', default='--allow-all-tools', help='Approval flags for all agents')
    
    # From config file
    from_config = subparsers.add_parser('from-config', help='Load agents from JSON config')
    from_config.add_argument('file', type=Path, help='Agent configuration file')
    
    # Interactive mode
    interactive = subparsers.add_parser('interactive', help='Interactive agent spawning')
    
    # Global options
    parser.add_argument('--max-agents', type=int, default=4, help='Max concurrent agents')
    parser.add_argument('--workspace', type=Path, default=Path.cwd(), help='Working directory')
    
    args = parser.parse_args()
    
    # Check copilot availability
    if subprocess.run(['which', 'copilot'], capture_output=True).returncode != 0:
        print(f"{Colors.RED}Error: GitHub Copilot CLI not found{Colors.NC}")
        sys.exit(1)
    
    # Create swarm
    swarm = AgentSwarm(args.workspace, args.max_agents)
    swarm.log("=== Parallel Agent System ===", Colors.MAGENTA)
    
    try:
        if args.command == 'quick':
            # Spawn agents from CLI args
            for i, task in enumerate(args.tasks):
                agent_name = f"agent-{i}"
                swarm.spawn_agent(agent_name, task, args.approval)
            
            results = swarm.execute()
            sys.exit(0 if all(results.values()) else 1)
        
        elif args.command == 'from-config':
            # Load from config file
            agent_configs = load_agent_config(args.file)
            
            for config in agent_configs:
                swarm.spawn_agent(
                    name=config['name'],
                    task=config['task'],
                    approval=config.get('approval', '--allow-all-tools')
                )
            
            results = swarm.execute()
            sys.exit(0 if all(results.values()) else 1)
        
        elif args.command == 'interactive':
            # Interactive mode
            swarm.log("Interactive mode - spawn agents one by one", Colors.CYAN)
            swarm.log("Enter 'done' when finished, 'cancel' to abort", Colors.CYAN)
            
            agent_count = 0
            while True:
                print(f"\n{Colors.BLUE}Agent {agent_count + 1}:{Colors.NC}")
                name = input("  Name (or 'done'/'cancel'): ").strip()
                
                if name.lower() == 'done':
                    break
                if name.lower() == 'cancel':
                    swarm.log("Cancelled", Colors.YELLOW)
                    sys.exit(1)
                
                task = input("  Task: ").strip()
                if not task:
                    continue
                
                approval = input("  Approval flags (default: --allow-all-tools): ").strip()
                if not approval:
                    approval = "--allow-all-tools"
                
                swarm.spawn_agent(name, task, approval)
                agent_count += 1
            
            if agent_count == 0:
                swarm.log("No agents created", Colors.YELLOW)
                sys.exit(0)
            
            results = swarm.execute()
            sys.exit(0 if all(results.values()) else 1)
        
        else:
            parser.print_help()
            sys.exit(1)
    
    except KeyboardInterrupt:
        swarm.log("\nInterrupted by user", Colors.YELLOW)
        sys.exit(1)
    except Exception as e:
        swarm.log(f"Fatal error: {e}", Colors.RED)
        sys.exit(1)


if __name__ == "__main__":
    main()
