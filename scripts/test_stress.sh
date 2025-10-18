#!/bin/bash
# Generate stress test for history implementation
echo "# Stress testing history with many commands"
for i in {1..50}; do
    echo "echo command$i"
done
echo "history"
echo "search command"
echo "exit"