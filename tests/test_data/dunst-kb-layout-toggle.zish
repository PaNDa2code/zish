#!/bin/bash
current_layout=$(setxkbmap -query | grep 'layout:' | cut -d ' ' -f 6)
layouts=("us" "fi")
layout_count=${#layouts[@]}
current_index=-1
for index in "${!layouts[@]}"; do
	if [ "${layouts[$index]}" == "$current_layout" ]; then
		current_index=$index
		break
	fi
done
next_index=$(((current_index + 1) % layout_count))
setxkbmap "${layouts[$next_index]}"
dunstify "Layout switched to ${layouts[$next_index]}" -t 400 -u normal
