#!/usr/bin/env bash
# Smoke test for the net10.0 build of dotnet-interactive (what runs where only the .NET 10 runtime is installed).
# It checks that the tool runs C# on a .NET 10 runtime AND that "#r nuget:" restores and loads a package, which
# exercises the net10.0 restore target framework in PackageRestoreContext.
#
# Usage: eng/smoke-test-net10.sh <path to net10.0 Microsoft.DotNet.Interactive.App.dll> <work dir> [timeout seconds]
set -u

dll="$1"
work="$2"
limit="${3:-300}"

mkdir -p "$work"
out="$work/net10-smoke.out"

if [[ ! -f "$dll" ]]; then
  echo "net10.0 build not found: $dll" >&2
  exit 1
fi

tokens=(net10-smoke-version net10-smoke-restore net10-smoke-use)
cmds=(
  '{"commandType":"SubmitCode","command":{"code":"System.Environment.Version.Major","targetKernelName":"csharp"},"token":"net10-smoke-version"}'
  '{"commandType":"SubmitCode","command":{"code":"#r \"nuget: Newtonsoft.Json, 13.0.3\"","targetKernelName":"csharp"},"token":"net10-smoke-restore"}'
  '{"commandType":"SubmitCode","command":{"code":"Newtonsoft.Json.JsonConvert.DeserializeObject<int>(\"4242\")","targetKernelName":"csharp"},"token":"net10-smoke-use"}'
)

: > "$out"

finished() {
  # $1 = token. Succeeds when the command with exactly that token has completed, one way or the other
  # (the host also reports sub-commands as "<token>.1", "<token>.2", ...).
  grep -q -E "\"eventType\":\"(CommandSucceeded|CommandFailed)\",\"command\":\{\"token\":\"$1\"" "$out"
}

deadline=$((SECONDS + limit))

# Commands are sent one at a time, each only after the previous one has completed, so that the package
# restored by the second command is loaded before the third one is compiled.
feed() {
  local i
  for i in "${!tokens[@]}"; do
    printf '%s\n' "${cmds[$i]}"
    until finished "${tokens[$i]}"; do
      (( SECONDS < deadline )) || return 0
      sleep 1
    done
  done
}

# The stdio host keeps running after stdin is exhausted, so run it in the background, wait for the outcome of
# each command, and stop it as soon as they have all finished (or the time limit is reached).
dotnet "$dll" stdio < <(feed) > "$out" 2>&1 &
pid=$!

while (( SECONDS < deadline )); do
  all=1
  for t in "${tokens[@]}"; do
    finished "$t" || { all=0; break; }
  done
  (( all )) && break
  if ! kill -0 "$pid" 2>/dev/null; then
    break # the host exited on its own, nothing more will be written
  fi
  sleep 2
done
kill "$pid" 2>/dev/null
sleep 1
kill -9 "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

fail() {
  echo "net10.0 smoke test failed: $1" >&2
  echo "---- host output (first 6000 chars) ----" >&2
  head -c 6000 "$out" >&2
  echo >&2
  exit 1
}

for t in "${tokens[@]}"; do
  finished "$t" || fail "command $t did not complete within ${limit}s"
done

# CommandFailed is only an error for the commands that are expected to succeed; all three are.
grep -q -E "\"eventType\":\"CommandFailed\",\"command\":\{\"token\":\"net10-smoke-" "$out" && fail "a command failed"

grep -q -E '<pre>10</pre>.*"eventType":"ReturnValueProduced"|"eventType":"ReturnValueProduced".*<pre>10</pre>' "$out" \
  || fail "net10.0 build did not return 10 for Environment.Version.Major"

grep -q -E '<pre>4242</pre>.*"eventType":"ReturnValueProduced"|"eventType":"ReturnValueProduced".*<pre>4242</pre>' "$out" \
  || fail "#r \"nuget: Newtonsoft.Json\" did not restore and load on the net10.0 build"

echo "net10.0 smoke test passed: Environment.Version.Major == 10 and a NuGet package restored and loaded."
