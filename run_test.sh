#!/bin/bash
zig build rom-test --summary all > test_output.txt 2>&1
cat test_output.txt
