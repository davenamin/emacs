# cross/xcode-build/xcode-toolchain.sh -- resolve the Apple toolchain
# for an iOS cross-compile.  POSIX shell, intended to be *sourced*
# (not executed) from configure.ac's recursive XCONFIGURE=ios path
# and from interactive debugging sessions.
#
# Inputs (environment variables):
#   IOS_SDK                  iphoneos (default) | iphonesimulator
#   IOS_ARCH                 arm64 (default) | x86_64 (simulator only)
#   IOS_DEPLOYMENT_TARGET    required, e.g. 15.0
#
# Outputs (exported):
#   CC, CXX, AR, RANLIB      absolute paths from xcrun
#   CFLAGS, OBJCFLAGS, LDFLAGS
#                            augmented with -arch / -isysroot /
#                            -m{ios,iphonesimulator}-version-min
#
# On failure, prints a diagnostic to stderr and returns non-zero
# without touching the caller's shell state beyond what was already
# exported.  Use `. xcode-toolchain.sh || exit' from configure.ac.

xcode_toolchain_die () {
  echo "cross/xcode-build/xcode-toolchain.sh: $*" >&2
  return 1
}

# 1. Sanity: we need a real Apple toolchain.  This rules out Linux
#    hosts, where configure --with-ios still configures cleanly but
#    the recursive cross step would just produce confusing errors
#    from a non-existent xcrun.
case `uname -s 2>/dev/null` in
  Darwin) ;;
  *) xcode_toolchain_die \
       "iOS cross-compile requires macOS with Xcode; uname is `uname -s`."
     return 1 ;;
esac

command -v xcrun >/dev/null 2>&1 || {
  xcode_toolchain_die \
    "'xcrun' not in PATH; install Xcode or the Command Line Tools."
  return 1
}

# 2. Defaults.
: "${IOS_SDK:=iphoneos}"
: "${IOS_ARCH:=arm64}"

case "$IOS_SDK" in
  iphoneos|iphonesimulator) ;;
  *) xcode_toolchain_die \
       "IOS_SDK must be iphoneos or iphonesimulator (got '$IOS_SDK')."
     return 1 ;;
esac

if test -z "$IOS_DEPLOYMENT_TARGET"; then
  xcode_toolchain_die "IOS_DEPLOYMENT_TARGET is required (e.g. 15.0)."
  return 1
fi

# 3. Resolve the SDK path and tool binaries.  xcrun does all the
#    Xcode-version-aware path discovery for us; we just have to
#    capture its output.
xcode_sdk_path=`xcrun --sdk "$IOS_SDK" --show-sdk-path 2>/dev/null` || {
  xcode_toolchain_die \
    "xcrun could not locate SDK '$IOS_SDK'; is Xcode installed?"
  return 1
}

xcode_cc=`xcrun --sdk "$IOS_SDK" -f clang 2>/dev/null`     || \
  { xcode_toolchain_die "xcrun -f clang failed"; return 1; }
xcode_cxx=`xcrun --sdk "$IOS_SDK" -f clang++ 2>/dev/null`  || \
  { xcode_toolchain_die "xcrun -f clang++ failed"; return 1; }
xcode_ar=`xcrun --sdk "$IOS_SDK" -f ar 2>/dev/null`        || \
  { xcode_toolchain_die "xcrun -f ar failed"; return 1; }
xcode_ranlib=`xcrun --sdk "$IOS_SDK" -f ranlib 2>/dev/null` || \
  { xcode_toolchain_die "xcrun -f ranlib failed"; return 1; }

# 4. Pick the right -m*-version-min flag.  Apple's clang distinguishes
#    device vs simulator at this level (-mios-version-min vs
#    -mios-simulator-version-min); using the wrong one silently
#    produces a binary that the loader rejects.
case "$IOS_SDK" in
  iphoneos)
    xcode_vmin="-mios-version-min=$IOS_DEPLOYMENT_TARGET" ;;
  iphonesimulator)
    xcode_vmin="-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET" ;;
esac

xcode_target_flags="-arch $IOS_ARCH -isysroot $xcode_sdk_path $xcode_vmin"

# 5. Export.  CFLAGS / OBJCFLAGS / LDFLAGS are *augmented* so that any
#    caller-supplied flags (e.g. -O2, -g) survive.
CC=$xcode_cc
CXX=$xcode_cxx
AR=$xcode_ar
RANLIB=$xcode_ranlib
CFLAGS="${CFLAGS:+$CFLAGS }$xcode_target_flags"
OBJCFLAGS="${OBJCFLAGS:+$OBJCFLAGS }$xcode_target_flags"
LDFLAGS="${LDFLAGS:+$LDFLAGS }$xcode_target_flags"

export CC CXX AR RANLIB CFLAGS OBJCFLAGS LDFLAGS

unset xcode_toolchain_die xcode_sdk_path xcode_cc xcode_cxx \
      xcode_ar xcode_ranlib xcode_vmin xcode_target_flags
