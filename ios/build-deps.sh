#!/bin/sh
### build-deps.sh --- cross-compile the TLS stack for the iOS port

## Copyright (C) 2026 Free Software Foundation, Inc.

## This file is part of GNU Emacs.

## GNU Emacs is free software: you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published
## by the Free Software Foundation, either version 3 of the License,
## or (at your option) any later version.

## GNU Emacs is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.

## You should have received a copy of the GNU General Public License
## along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

### Commentary:

## Build GnuTLS and its dependencies (GMP, Nettle) as static
## libraries for iOS, producing an install prefix that
## configure --with-ios-deps=PREFIX consumes.  This is the iOS
## counterpart of the Android port's arrangement, where GnuTLS,
## libgmp, nettle etc. are cross-compiled and bundled with the app
## (java/INSTALL, section GNUTLS).  Android needs specially
## repackaged ndk-build sources; iOS is an ordinary autoconf cross
## target, so the packages' own configure scripts work with --host
## and the Apple toolchain.
##
## Usage:
##   ios/build-deps.sh [--sdk iphoneos|iphonesimulator]
##                     [--arch arm64] [--min VERSION]
##                     [--prefix DIR] [--jobs N]
##
## Defaults: --sdk iphoneos, --arch arm64, --min 15.0,
## --prefix $PWD/ios-deps/<sdk>, --jobs = hw.ncpu.
##
## The script is a fast no-op when PREFIX already contains
## lib/pkgconfig/gnutls.pc (so CI can cache the prefix).  Source
## tarballs are fetched from the projects' official release hosts
## into PREFIX/../downloads; drop independently verified tarballs
## there beforehand if you want to avoid the network fetch --
## anything already present is used as-is.  SHA-256 digests of
## everything used are printed for the build log.
##
## Licensing: GnuTLS is LGPLv2.1+; Nettle is dual GPLv2+/LGPLv3+;
## GMP is dual GPLv2+/LGPLv3+.  All are compatible with linking
## into GPLv3+ Emacs.

set -e

GMP_VERSION=6.3.0
NETTLE_VERSION=3.10.1
GNUTLS_VERSION=3.8.9

GMP_URL="https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VERSION.tar.xz"
NETTLE_URL="https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_VERSION.tar.gz"
GNUTLS_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v${GNUTLS_VERSION%.*}/gnutls-$GNUTLS_VERSION.tar.xz"

sdk=iphoneos
arch=arm64
minver=15.0
prefix=
jobs=

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk)    sdk="$2"; shift 2 ;;
    --arch)   arch="$2"; shift 2 ;;
    --min)    minver="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --jobs)   jobs="$2"; shift 2 ;;
    --help|-h)
      sed -n 's/^## //p' "$0" | sed -n '/^Usage:/,/^$/p'
      exit 0 ;;
    *)
      echo "build-deps.sh: unknown option $1 (try --help)" >&2
      exit 2 ;;
  esac
done

case "$sdk" in
  iphoneos|iphonesimulator) ;;
  *) echo "build-deps.sh: --sdk must be iphoneos or iphonesimulator" >&2
     exit 2 ;;
esac

test -n "$prefix" || prefix="$PWD/ios-deps/$sdk"
## Make the prefix absolute; it is baked into .pc files.
case "$prefix" in
  /*) ;;
  *) prefix="$PWD/$prefix" ;;
esac
test -n "$jobs" || jobs=`sysctl -n hw.ncpu 2>/dev/null || echo 4`

if [ -f "$prefix/lib/pkgconfig/gnutls.pc" ]; then
  echo "build-deps.sh: $prefix already contains gnutls.pc; nothing to do."
  exit 0
fi

command -v xcrun >/dev/null 2>&1 || {
  echo "build-deps.sh: xcrun not found; this script requires macOS with Xcode." >&2
  exit 1
}
command -v pkg-config >/dev/null 2>&1 || {
  echo "build-deps.sh: pkg-config not found." >&2
  echo "  Homebrew: brew install pkg-config" >&2
  echo "  Nix:      nix shell nixpkgs#pkg-config" >&2
  exit 1
}

## Resolve the whole binutils surface through xcrun, not just the
## compiler.  The packages' configure scripts otherwise take ar /
## ranlib / strip from PATH, and environments that put non-Apple
## toolchains first (Nix shells with a stdenv compiler, GNU
## binutils installs) would corrupt the static archives or their
## symbol tables.
CC=`xcrun --sdk "$sdk" --find clang`
AR=`xcrun --sdk "$sdk" --find ar`
RANLIB=`xcrun --sdk "$sdk" --find ranlib`
STRIP=`xcrun --sdk "$sdk" --find strip`
SDKROOT=`xcrun --sdk "$sdk" --show-sdk-path`

if [ "$sdk" = iphonesimulator ]; then
  min_flag="-mios-simulator-version-min=$minver"
else
  min_flag="-miphoneos-version-min=$minver"
fi

## -fembed-bitcode is dead; -O2 everywhere.  The same triple the
## Emacs cross build itself uses (aarch64-apple-darwin) keeps every
## package's config.sub happy.
host_triple=aarch64-apple-darwin
target_cflags="-arch $arch -isysroot $SDKROOT $min_flag -O2"

downloads="$prefix/../downloads"
work="$prefix/../build-$sdk"
mkdir -p "$prefix" "$downloads" "$work"
## Absolute paths for the dirs we just created.
downloads=`cd "$downloads" && pwd`
work=`cd "$work" && pwd`
prefix=`cd "$prefix" && pwd`

fetch ()
{
  url="$1"
  file="$downloads/`basename "$url"`"
  if [ ! -f "$file" ]; then
    echo "build-deps.sh: fetching $url"
    curl -fL --retry 3 -o "$file.tmp" "$url"
    mv "$file.tmp" "$file"
  fi
  echo "build-deps.sh: using `shasum -a 256 "$file"`"
}

unpack ()
{
  file="$downloads/$1"
  dir="$work/$2"
  rm -rf "$dir"
  ( cd "$work" && tar xf "$file" )
  test -d "$dir" || {
    echo "build-deps.sh: $file did not unpack to $2" >&2
    exit 1
  }
}

log="$work/build.log"
: > "$log"
echo "build-deps.sh: sdk=$sdk arch=$arch min=$minver prefix=$prefix"
echo "build-deps.sh: full compile output in $log"

## Run one package build; on failure surface the log tail (CI
## captures only this script's stdout -- the build log lives on
## the runner and would otherwise vanish with it).
build_failed ()
{
  echo "build-deps.sh: $1 FAILED; last 80 lines of $log:" >&2
  tail -80 "$log" >&2
  exit 1
}

## ---- GMP --------------------------------------------------------
## --disable-assembly: like the nettle and gnutls assembler
## disables below, prefer the portable C paths over
## assembler-dialect roulette with Apple's integrated assembler;
## public-key performance remains more than adequate for TLS
## handshakes.
fetch "$GMP_URL"
unpack "gmp-$GMP_VERSION.tar.xz" "gmp-$GMP_VERSION"
echo "build-deps.sh: building gmp-$GMP_VERSION"
( cd "$work/gmp-$GMP_VERSION" \
  && ./configure --host=$host_triple --prefix="$prefix" \
       --enable-static --disable-shared --disable-assembly \
       CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
       CFLAGS="$target_cflags" \
  && make -j"$jobs" && make install ) >> "$log" 2>&1 \
  || build_failed "gmp-$GMP_VERSION"

## ---- Nettle -----------------------------------------------------
## --disable-assembler: Nettle's aarch64 assembly is written for
## GNU as; Apple's integrated assembler rejects it (ELF section
## directives, %-prefixed type annotations).  The C
## implementations are fully portable.
##
## ac_cv_type_uid_t=yes: Nettle ships a configure generated by
## autoconf 2.69, whose AC_TYPE_UID_T probes by grepping the BUILD
## host's /usr/include/sys/types.h -- a directory that does not
## exist on modern macOS -- so it concludes uid_t is missing,
## config.h defines uid_t/gid_t as int, and the first SDK header
## that typedefs the real ones fails to compile.  Autoconf 2.70+
## turned the macro into a compile check; seed the cache var for
## every dependency whose configure predates that fix.
fetch "$NETTLE_URL"
unpack "nettle-$NETTLE_VERSION.tar.gz" "nettle-$NETTLE_VERSION"
echo "build-deps.sh: building nettle-$NETTLE_VERSION"
( cd "$work/nettle-$NETTLE_VERSION" \
  && ./configure --host=$host_triple --prefix="$prefix" \
       --disable-shared --disable-documentation \
       --disable-assembler \
       ac_cv_type_uid_t=yes \
       CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
       CFLAGS="$target_cflags -I$prefix/include" \
       LDFLAGS="-L$prefix/lib" \
  && make -j"$jobs" && make install ) >> "$log" 2>&1 \
  || build_failed "nettle-$NETTLE_VERSION"

## ---- GnuTLS -----------------------------------------------------
## Included libtasn1 and unistring keep the dependency set at
## three packages (the Android port carries separate libtasn1 and
## p11-kit; neither is needed when PKCS#11 support is off).  No
## default trust store is configured -- Emacs passes trust anchors
## explicitly through gnutls-trustfiles, which lisp/term/ios-win.el
## points at the ca-bundle.pem the bundle ships.
## --disable-hardware-acceleration: GnuTLS's lib/accelerated
## aarch64 assembly is GNU-as flavored like Nettle's; the C code
## paths avoid the same Apple-assembler incompatibility.
fetch "$GNUTLS_URL"
unpack "gnutls-$GNUTLS_VERSION.tar.xz" "gnutls-$GNUTLS_VERSION"
echo "build-deps.sh: building gnutls-$GNUTLS_VERSION"
( cd "$work/gnutls-$GNUTLS_VERSION" \
  && ./configure --host=$host_triple --prefix="$prefix" \
       --enable-static --disable-shared \
       --with-included-libtasn1 --with-included-unistring \
       --without-p11-kit --without-idn --without-brotli \
       --without-zstd --without-zlib --without-tpm --without-tpm2 \
       --disable-libdane --disable-doc --disable-tools \
       --disable-tests --disable-cxx --disable-nls \
       --disable-guile --disable-hardware-acceleration \
       ac_cv_type_uid_t=yes \
       CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
       CFLAGS="$target_cflags -I$prefix/include" \
       LDFLAGS="-L$prefix/lib" \
       PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
  && make -j"$jobs" && make install ) >> "$log" 2>&1 \
  || build_failed "gnutls-$GNUTLS_VERSION"

## ---- Post-process gnutls.pc for static linking -------------------
## Emacs's configure queries pkg-config without --static, so fold
## the private dependency closure into the public Libs line; the
## archives are static, so the closure must appear on the final
## link command.
pc="$prefix/lib/pkgconfig/gnutls.pc"
sed -e 's|^Libs:.*|Libs: -L${libdir} -lgnutls -lhogweed -lnettle -lgmp|' \
    "$pc" > "$pc.tmp"
mv "$pc.tmp" "$pc"

echo "build-deps.sh: done."
echo "build-deps.sh: configure Emacs with --with-ios-deps=$prefix"
