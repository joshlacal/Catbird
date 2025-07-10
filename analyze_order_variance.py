#!/usr/bin/env python3
"""
Analyze FaultOrdering address sequences to find stable startup order
"""

# First run addresses (in order)
first_run = [
    4294969536, 4294978664, 4294978776, 4294976309,
    4294973638, 4294975875, 4294975831, 4294978639,
    4294971417, 4294976047, 4294975822, 4294973453,
    4294975957, 4294971443, 4294975638, 4294976399,
    4294978613, 4294975849, 4294971433, 4294975806,
    4294973654, 4294978261, 4294976063, 4294975655,
    4294975840, 4294976227, 4294976145, 4294973648
]

# Second run addresses (in order)
second_run = [
    4294971433, 4294976145, 4294976063, 4294973654,
    4294975957, 4294973638, 4294978639, 4294969536,
    4294976047, 4294975875, 4294975822, 4294973453,
    4294978664, 4294976309, 4294971417, 4294975638,
    4294971443, 4294975831, 4294975840, 4294973648,
    4294978261, 4294976399, 4294975806, 4294975655,
    4294975849, 4294976227, 4294978776, 4294978613
]

# Find common early addresses (stable startup sequence)
def find_stable_startup_sequence(run1, run2, threshold=0.5):
    """Find addresses that appear early in both runs"""
    stable = []
    
    # Look at first half of addresses
    early_count = int(len(run1) * threshold)
    early_run1 = set(run1[:early_count])
    early_run2 = set(run2[:early_count])
    
    # Find addresses that appear early in both runs
    common_early = early_run1.intersection(early_run2)
    
    # Order by average position
    addr_positions = {}
    for addr in common_early:
        pos1 = run1.index(addr)
        pos2 = run2.index(addr)
        avg_pos = (pos1 + pos2) / 2
        addr_positions[addr] = avg_pos
    
    # Sort by average position
    stable = sorted(addr_positions.keys(), key=lambda x: addr_positions[x])
    
    return stable, addr_positions

# Analyze the runs
stable_addrs, positions = find_stable_startup_sequence(first_run, second_run)

print("# Order File Analysis")
print(f"# Total addresses: {len(first_run)}")
print(f"# Addresses in different order between runs: YES")
print()

print("# Stable early startup addresses (appear early in both runs):")
for addr in stable_addrs:
    pos1 = first_run.index(addr)
    pos2 = second_run.index(addr)
    print(f"0x{addr:08X}  # Position: Run1[{pos1}], Run2[{pos2}], Avg[{positions[addr]:.1f}]")

print()
print("# All addresses from first run (temporal order):")
for i, addr in enumerate(first_run):
    pos2 = second_run.index(addr)
    diff = abs(i - pos2)
    stability = "STABLE" if diff <= 3 else "VARIABLE"
    print(f"0x{addr:08X}  # [{i}] -> [{pos2}] diff={diff} {stability}")

print()
print("# Recommended approach:")
print("# 1. Use first run order as baseline")
print("# 2. Run more tests to identify truly stable addresses")
print("# 3. Consider separating order file into sections:")
print("#    - Critical startup (addresses 0-10)")
print("#    - Secondary init (addresses 11-20)")
print("#    - Post-launch (addresses 21-27)")
