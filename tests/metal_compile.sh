#!/bin/sh
# Every *.metal file under DIR compiled by Apple's Metal compiler, for macOS and for iOS,
# with fast math off (as a Metal host must compile BULG's texts: see docs/targets.md).
#
#   tests/metal_compile.sh DIR
#
# Prints each failure with the compiler's message, then the count and the time taken.
# Exits 1 if any file fails. Needs Xcode's Metal toolchain (`xcrun metal -v`; since
# Xcode 26 it is a separate component: `xcodebuild -downloadComponent MetalToolchain`).
set -u
dir=${1:?usage: tests/metal_compile.sh DIR}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
n=0
bad=0
start=$(date +%s)
for f in $(find "$dir" -name '*.metal' | sort); do
  n=$((n + 1))
  for sdk in macosx iphoneos; do
    if ! xcrun -sdk "$sdk" metal -fno-fast-math -c "$f" -o "$tmp/out.air" 2> "$tmp/log"; then
      bad=$((bad + 1))
      echo "$f ($sdk):"
      sed 's/^/  /' "$tmp/log" | head -20
    elif [ -s "$tmp/log" ]; then
      echo "$f ($sdk) warns:"
      sed 's/^/  /' "$tmp/log" | head -10
    fi
  done
done
echo "metal: $((2 * n - bad)) of $((2 * n)) compiled ($n files, macOS and iOS) in $(($(date +%s) - start)) s"
[ "$bad" -eq 0 ]
