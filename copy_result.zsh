#!/usr/bin/env zsh
set -eu

if (( ! $+commands[pbcopy] )); then
   print -u 2 -- "Command 'pbcopy' not found. Please consider using alias"
   exit 1
fi

if (( $# < 2 )); then
   print -u 2 -- "usage: $0 megido_name evolution_num"
   exit 1
fi

local result=result/$1.txt
if [[ ! -f $result ]]; then
   ./count_item.rb $1
fi
cat $result | head -n $2 | pbcopy
