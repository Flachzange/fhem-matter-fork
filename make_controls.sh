#!/bin/bash
echo "# FHEM Controls" > controls_matter.txt
for file in FHEM/*.pm; do
    if [ -f "$file" ]; then
        size=$(wc -c < "$file" | tr -d ' ')
        date=$(date -r "$file" +%Y-%m-%d_%H:%M:%S)
        echo "UPD $file $size $date" >> controls_matter.txt
    fi
done