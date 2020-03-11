#!/usr/bin/env zsh
set -eu

if (( ! $+commands[pbcopy] )) && (( ! $+aliases[pbcopy] )); then
   print -u 2 -- "Command 'pbcopy' not found. Please consider using alias"
   exit 1
fi

local -A opthash
zparseopts -D -M -A opthash -- \
   -help h=-help \
   -reload r=-reload

if (( $+opthash[--help] )) || (( $# < 2 )); then
   print -u 2 -- "usage: $0 [-r] mode name"
   exit 1
fi

local mode=$1
local name=$2

local result=result/$mode/$name.txt
if (( $+opthash[--reload] )) || [[ ! -f $result ]]; then
   ./get_materials.rb $mode $name
fi
cat $result | pbcopy
