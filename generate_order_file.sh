#!/bin/bash

# Script to generate order file from console addresses

echo "# Order file generated from FaultOrdering addresses"
echo "# Generated on: $(date)"
echo "# Total addresses: 28"
echo ""

# The 28 addresses from console output, sorted
addresses=(
    4294969536
    4294971417
    4294971433
    4294971443
    4294973453
    4294973638
    4294973648
    4294973654
    4294975638
    4294975655
    4294975806
    4294975822
    4294975831
    4294975840
    4294975849
    4294975875
    4294975957
    4294976047
    4294976063
    4294976145
    4294976227
    4294976309
    4294976399
    4294978261
    4294978613
    4294978639
    4294978664
    4294978776
)

# Sort and print as hex
for addr in $(printf '%s\n' "${addresses[@]}" | sort -n); do
    printf "0x%08X\n" $addr
done

echo ""
echo "# End of order file"
