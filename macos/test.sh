#!/usr/bin/env bash
# Corre os testes. Só com as Command Line Tools (sem Xcode), o Swift Build às vezes não encontra
# o plugin de macros do swift-testing ("plugin for module 'TestingMacros' not found"); nesse caso
# repete do zero. Com Xcode instalado basta `swift test`.
set -uo pipefail
cd "$(dirname "$0")"
for attempt in 1 2 3; do
    rm -rf .build/test
    log="$(swift test --scratch-path .build/test "$@" 2>&1)"
    status=$?
    if [ $status -eq 0 ] || ! grep -q "plugin for module 'TestingMacros'" <<<"$log"; then
        echo "$log" | grep -v "^\[" 
        exit $status
    fi
    echo "↻ plugin de macros não encontrado (tentativa $attempt); a repetir…"
done
echo "$log"
exit 1
