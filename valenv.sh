#!/bin/bash
while [[ $# -gt 0 ]]
do
	val=$(eval $(echo echo "$"$1))
	if [ -z "$val" ]; then
		echo "The required environment variable \$"$1" is not set"
		exit 1
	fi
	shift
done
