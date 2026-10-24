#!/bin/bash
# Tests for the bash completion in completions/check_storcli.
# Usage: tests/test_completion.sh

cd "$(dirname "$0")/.." || exit 1
COMPLETION=completions/check_storcli
fail=0
count=0

# complete WORD...: the candidates bash offers for the last word, one per line
complete_words() {
    bash -c 'source "$1"; shift; COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); _check_storcli; printf "%s\n" "${COMPREPLY[@]}"' \
        bash "$PWD/$COMPLETION" check_storcli "$@" | LC_ALL=C sort
}

# expect NAME "EXPECTED CANDIDATES" WORD...
expect() {
    local name=$1 want=$2; shift 2
    local got
    got=$(complete_words "$@" | paste -sd ' ')
    count=$((count + 1))
    if [ "$got" = "$want" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: got '$got', want '$want'"
        fail=1
    fi
}

count=$((count + 1))
if bash -n "$COMPLETION"; then echo "ok   syntax"; else echo "FAIL syntax"; fail=1; fi

# the options of the help, as "  -x  description" lines
help_options=$(./check_storcli -h | sed -n 's/^  \(-[A-Za-z]\)  .*/\1/p' | LC_ALL=C sort | paste -sd ' ')
expect "offers exactly the options of -h" "$help_options" ""
expect "option prefix is case-sensitive" "-R" "-R"
expect "options after an option" "-R -S -V -c -h -m -r -s -t -w" "-S" "-"
expect "no value for thresholds" "" "-w" ""
expect "no value for the timeout" "" "-S" "-t" ""

tmp=$(mktemp -d) || exit 1
touch "$tmp/storcli64"
expect "storcli path" "$tmp/storcli64" "-s" "$tmp/stor"
rm -f "$tmp/storcli64" && rmdir "$tmp"

echo "$count tests, $([ $fail -eq 0 ] && echo "all passed" || echo "FAILURES")"
exit $fail
