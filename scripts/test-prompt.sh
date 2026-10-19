#!/bin/zsh
# Runs each line of a cases file through the running llama-server using the app's exact cleanup prompt.
# Usage: scripts/test-prompt.sh [cases.txt]   (llama-server must be listening on 127.0.0.1:8178)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASES="${1:-$ROOT/scripts/cases.txt}"
SRC="$ROOT/Sources/LocalFlow/Cleaner.swift"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Pull the system prompt and few-shot examples out of Cleaner.swift so this never drifts from the app.
perl -0ne 'if (/var text = """\n(.*?)\n\s*"""/s) { $t=$1; $t =~ s/^ {8}//mg; $t =~ s/\\\n//g; print $t }' "$SRC" > "$TMP/system.txt"
perl -0ne 'if (/static let examples.*?= \[\n(.*?)\n\s*\]\n/s) { $b=$1; while ($b =~ /\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\)/sg) { print "$1\t$2\n" } }' "$SRC" > "$TMP/examples.tsv"
jq -Rs '.' "$TMP/system.txt" > "$TMP/sys.json"

now() { perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' }

while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  body=$(jq -n --slurpfile s "$TMP/sys.json" --rawfile ex "$TMP/examples.tsv" --arg t "$line" --arg app "${APP:-Notes}" '
    {messages: ([{role:"system",content:$s[0]}]
      + ([$ex | split("\n")[] | select(length>0) | split("\t")
          | ({role:"user",content:("App: Notes\n<transcript>"+.[0]+"</transcript>")},
             {role:"assistant",content:(.[1]|gsub("\\\\n";"\n"))})])
      + [{role:"user",content:("App: \($app)\n<transcript>"+$t+"</transcript>")}]),
     temperature:0, max_tokens:(($t|length)/2+64|floor), cache_prompt:true}')
  start=$(now)
  out=$(curl -s http://127.0.0.1:8178/v1/chat/completions -H 'Content-Type: application/json' -d "$body" \
        | jq -r '.choices[0].message.content')
  echo "IN : $line"
  echo "OUT ($(( $(now) - start )) ms): $out"
  echo
done < "$CASES"
