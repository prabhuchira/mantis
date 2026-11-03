#!/bin/sh
# Exercises the emulator: SGR styles, 16/256/truecolor, box drawing, blocks, wide chars, links.
printf '\033]0;Mantis demo\007'
printf '\033[1mMantis\033[0m — a native macOS terminal  \033[2m(TERM=%s, %sx%s)\033[0m\n\n' "$TERM" "$(tput cols)" "$(tput lines)"
printf 'styles: \033[1mbold\033[0m \033[3mitalic\033[0m \033[4munderline\033[0m \033[4:3mcurly\033[0m \033[21mdouble\033[0m \033[9mstrike\033[0m \033[7minverse\033[0m \033[2mdim\033[0m \033[53moverline\033[0m\n'
printf '16:     '; for i in 0 1 2 3 4 5 6 7; do printf '\033[4%sm  \033[0m' $i; done; printf ' '; for i in 0 1 2 3 4 5 6 7; do printf '\033[10%sm  \033[0m' $i; done; printf '\n'
printf '256:    '; i=16; while [ $i -lt 232 ]; do printf '\033[48;5;%sm \033[0m' $i; i=$((i+3)); done; printf '\n'
printf 'true:   '; i=0; while [ $i -lt 72 ]; do r=$((255-i*3)); g=$((i*3)); b=$((128+i)); printf '\033[48;2;%s;%s;%sm \033[0m' $r $g $b; i=$((i+1)); done; printf '\n\n'
printf '┌──────────┬──────────┐  ╭────────╮  ▁▂▃▄▅▆▇█  ░▒▓█\n'
printf '│ \033[32mpassing\033[0m  │ \033[31mfailing\033[0m  │  │ rounded│  ▏▎▍▌▋▊▉█  ▀▄▌▐\n'
printf '├──────────┼──────────┤  ╰────────╯\n'
printf '│  \033[1;32m128\033[0m     │   \033[1;31m3\033[0m      │  wide: 漢字 かな 한글 🙂🚀  é ñ ü\n'
printf '└──────────┴──────────┘  link: \033]8;;https://example.com\033\\example.com (⌘-click)\033]8;;\033\\\n\n'
printf '\033[38;5;245m$ \033[0mls --color\n'
ls -G /Users 2>/dev/null | head -5
