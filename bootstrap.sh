#!/bin/sh

set -v
set -e
set -u

export DEB_BUILD_OPTIONS="nocheck noddebs parallel=1"
export DH_VERBOSE=1
HOST_ARCH=undefined
# select gcc version from gcc-defaults package unless set
GCC_VER=
: ${MIRROR:="http://http.debian.net/debian"}
ENABLE_MULTILIB=no
ENABLE_MULTIARCH_GCC=yes
REPODIR=/tmp/repo
APT_GET="apt-get --no-install-recommends -y -o Debug::pkgProblemResolver=true -o Debug::pkgDepCache::Marker=1 -o Debug::pkgDepCache::AutoInstall=1 -o Acquire::Languages=none -o Debug::BuildDeps=1"
DEFAULT_PROFILES="cross nocheck noinsttest noudeb"
LIBC_NAME=glibc
DROP_PRIVS=buildd
GCC_NOLANG="ada asan brig d go itm java jit hppa64 lsan m2 nvptx objc obj-c++ tsan ubsan"
ENABLE_DIFFOSCOPE=no

if df -t tmpfs /var/cache/apt/archives >/dev/null 2>&1; then
	APT_GET="$APT_GET -o APT::Keep-Downloaded-Packages=false"
fi

if test "$(hostname -f)" = ionos9-amd64.debian.net; then
	# jenkin's proxy fails very often
	echo 'APT::Acquire::Retries "10";' > /etc/apt/apt.conf.d/80-retries
fi

# evaluate command line parameters of the form KEY=VALUE
for param in "$@"; do
	echo "bootstrap-configuration: $param"
	eval $param
done

# test whether element $2 is in set $1
set_contains() {
	case " $1 " in
		*" $2 "*) return 0; ;;
		*) return 1; ;;
	esac
}

# add element $2 to set $1
set_add() {
	case " $1 " in
		"  ") echo "$2" ;;
		*" $2 "*) echo "$1" ;;
		*) echo "$1 $2" ;;
	esac
}

# remove element $2 from set $1
set_discard() {
	local word result
	if set_contains "$1" "$2"; then
		result=
		for word in $1; do
			test "$word" = "$2" || result="$result $word"
		done
		echo "${result# }"
	else
		echo "$1"
	fi
}

# create a set from a string of words with duplicates and excess white space
set_create() {
	local word result
	result=
	for word in $1; do
		result=`set_add "$result" "$word"`
	done
	echo "$result"
}

# intersect two sets
set_intersect() {
	local word result
	result=
	for word in $1; do
		if set_contains "$2" "$word"; then
			result=`set_add "$result" "$word"`
		fi
	done
	echo "$result"
}

# compute the set of elements in set $1 but not in set $2
set_difference() {
	local word result
	result=
	for word in $1; do
		if ! set_contains "$2" "$word"; then
			result=`set_add "$result" "$word"`
		fi
	done
	echo "$result"
}

# compute the union of two sets $1 and $2
set_union() {
	local word result
	result=$1
	for word in $2; do
		result=`set_add "$result" "$word"`
	done
	echo "$result"
}

# join the words the arguments starting with $2 with separator $1
join_words() {
	local separator word result
	separator=$1
	shift
	result=
	for word in "$@"; do
		result="${result:+$result$separator}$word"
	done
	echo "$result"
}

check_arch() {
	# Work around arch-test not supporting ARC
	if test "$HOST_ARCH" = arc; then
		return 0
	fi
	if elf-arch -a "$2" "$1"; then
		return 0
	else
		echo "expected $2, but found $(file -b "$1")"
		return 1
	fi
}

filter_dpkg_tracked() {
	local pkg pkgs
	pkgs=""
	for pkg in "$@"; do
		dpkg-query -s "$pkg" >/dev/null 2>&1 && pkgs=`set_add "$pkgs" "$pkg"`
	done
	echo "$pkgs"
}

apt_get_install() {
	DEBIAN_FRONTEND=noninteractive $APT_GET install "$@"
}

apt_get_build_dep() {
	DEBIAN_FRONTEND=noninteractive $APT_GET build-dep "$@"
}

apt_get_remove() {
	local pkgs
	pkgs=$(filter_dpkg_tracked "$@")
	if test -n "$pkgs"; then
		$APT_GET remove $pkgs
	fi
}

apt_get_purge() {
	local pkgs
	pkgs=$(filter_dpkg_tracked "$@")
	if test -n "$pkgs"; then
		$APT_GET purge $pkgs
	fi
}

$APT_GET update
$APT_GET dist-upgrade # we need upgrade later, so make sure the system is clean
apt_get_install build-essential debhelper reprepro quilt arch-test

if test -z "$DROP_PRIVS"; then
	drop_privs_exec() {
		exec env -- "$@"
	}
else
	$APT_GET install adduser fakeroot
	if ! getent passwd "$DROP_PRIVS" >/dev/null; then
		adduser --system --group --home /tmp/buildd --no-create-home --shell /bin/false "$DROP_PRIVS"
	fi
	drop_privs_exec() {
		exec /sbin/runuser --user "$DROP_PRIVS" --group "$DROP_PRIVS" -- /usr/bin/env -- "$@"
	}
fi
drop_privs() {
	( drop_privs_exec "$@" )
}

if test "$ENABLE_MULTIARCH_GCC" = yes; then
	$APT_GET install cross-gcc-dev
	echo "removing unused unstripped_exe patch"
	sed -i '/made-unstripped_exe-setting-overridable/d' /usr/share/cross-gcc/patches/gcc-*/series
fi

obtain_source_package() {
	local use_experimental
	use_experimental=
	case "$1" in
		binutils)
			test "$GCC_VER" = 11 && use_experimental=yes
		;;
		gcc-[0-9]*)
			test -n "$(apt-cache showsrc "$1")" || use_experimental=yes
		;;
	esac
	if test "$use_experimental" = yes; then
		echo "deb-src $MIRROR experimental main" > /etc/apt/sources.list.d/tmp-experimental.list
		$APT_GET update
	fi
	drop_privs apt-get source "$1"
	if test -f /etc/apt/sources.list.d/tmp-experimental.list; then
		rm /etc/apt/sources.list.d/tmp-experimental.list
		$APT_GET update
	fi
}

# #980963
cat <<EOF >> /usr/share/dpkg/cputable
arc		arc		arc		32	little
EOF

if test -z "$HOST_ARCH" || ! dpkg-architecture "-a$HOST_ARCH"; then
	echo "architecture $HOST_ARCH unknown to dpkg"
	exit 1
fi

# ensure that the rebootstrap list comes first
test -f /etc/apt/sources.list && mv -v /etc/apt/sources.list /etc/apt/sources.list.d/local.list
for f in /etc/apt/sources.list.d/*.list; do
	test -f "$f" && sed -i "s/^deb \(\[.*\] \)*/deb [ arch-=$HOST_ARCH ] /" $f
done
grep -q '^deb-src .*sid' /etc/apt/sources.list.d/*.list || echo "deb-src $MIRROR sid main" >> /etc/apt/sources.list.d/sid-source.list

dpkg --add-architecture $HOST_ARCH
$APT_GET update

if test -z "$GCC_VER"; then
	GCC_VER=`apt-cache depends gcc | sed 's/^ *Depends: gcc-\([0-9.]*\)$/\1/;t;d'`
fi

rm -Rf /tmp/buildd
drop_privs mkdir -p /tmp/buildd

HOST_ARCH_SUFFIX="-`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_GNU_TYPE | tr _ -`"

case "$HOST_ARCH" in
	amd64) MULTILIB_NAMES="i386 x32" ;;
	i386) MULTILIB_NAMES="amd64 x32" ;;
	mips|mipsel) MULTILIB_NAMES="mips64 mipsn32" ;;
	mips64|mips64el) MULTILIB_NAMES="mips32 mipsn32" ;;
	mipsn32|mipsn32el) MULTILIB_NAMES="mips32 mips64" ;;
	powerpc) MULTILIB_NAMES=ppc64 ;;
	ppc64) MULTILIB_NAMES=powerpc ;;
	s390x) MULTILIB_NAMES=s390 ;;
	sparc) MULTILIB_NAMES=sparc64 ;;
	sparc64) MULTILIB_NAMES=sparc ;;
	x32) MULTILIB_NAMES="amd64 i386" ;;
	*) MULTILIB_NAMES="" ;;
esac
if test "$ENABLE_MULTILIB" != yes; then
	MULTILIB_NAMES=""
fi

mkdir -p "$REPODIR/conf" "$REPODIR/archive" "$REPODIR/stamps"
cat > "$REPODIR/conf/distributions" <<EOF
Codename: rebootstrap
Label: rebootstrap
Architectures: `dpkg --print-architecture` $HOST_ARCH
Components: main
UDebComponents: main
Description: cross toolchain and build results for $HOST_ARCH

Codename: rebootstrap-native
Label: rebootstrap-native
Architectures: `dpkg --print-architecture`
Components: main
UDebComponents: main
Description: native packages needed for bootstrap
EOF
cat > "$REPODIR/conf/options" <<EOF
verbose
ignore wrongdistribution
EOF
export REPREPRO_BASE_DIR="$REPODIR"
reprepro export
echo "deb [ arch=$(dpkg --print-architecture),$HOST_ARCH trusted=yes ] file://$REPODIR rebootstrap main" >/etc/apt/sources.list.d/000_rebootstrap.list
echo "deb [ arch=$(dpkg --print-architecture) trusted=yes ] file://$REPODIR rebootstrap-native main" >/etc/apt/sources.list.d/001_rebootstrap-native.list
cat >/etc/apt/preferences.d/rebootstrap.pref <<EOF
Explanation: prefer our own rebootstrap (native) packages over everything
Package: *
Pin: release l=rebootstrap-native
Pin-Priority: 1001

Explanation: prefer our own rebootstrap (toolchain) packages over everything
Package: *
Pin: release l=rebootstrap
Pin-Priority: 1002

Explanation: do not use archive cross toolchain
Package: *-$HOST_ARCH-cross *$HOST_ARCH_SUFFIX gcc-*$HOST_ARCH_SUFFIX-base
Pin: release a=unstable
Pin-Priority: -1
EOF
$APT_GET update

# Since most libraries (e.g. libgcc_s) do not include ABI-tags,
# glibc may be confused and try to use them. A typical symptom is:
# apt-get: error while loading shared libraries: /lib/x86_64-kfreebsd-gnu/libgcc_s.so.1: ELF file OS ABI invalid
cat >/etc/dpkg/dpkg.cfg.d/ignore-foreign-linker-paths <<EOF
path-exclude=/etc/ld.so.conf.d/$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_MULTIARCH).conf
EOF

# Work around Multi-Arch: same file conflict in libxdmcp-dev. #825146
cat >/etc/dpkg/dpkg.cfg.d/bug-825146 <<'EOF'
path-exclude=/usr/share/doc/libxdmcp-dev/xdmcp.txt.gz
EOF

# Work around binNMU file conflicts of e.g. binutils or gcc.
cat >/etc/dpkg/dpkg.cfg.d/binNMU-changelogs <<EOF
path-exclude=/usr/share/doc/*/changelog.Debian.$(dpkg-architecture -qDEB_BUILD_ARCH).gz
EOF

if test "$HOST_ARCH" = nios2; then
	echo "fixing libtool's nios2 misdetection as os2 #851253"
	apt_get_install libtool
	sed -i -e 's/\*os2\*/*-os2*/' /usr/share/libtool/build-aux/ltmain.sh
fi

# removing libc*-dev conflict with each other
LIBC_DEV_PKG=$(apt-cache showpkg libc-dev | sed '1,/^Reverse Provides:/d;s/ .*//;q')
if test "$(apt-cache show "$LIBC_DEV_PKG" | sed -n 's/^Source: //;T;p;q')" = glibc; then
if test -f "$REPODIR/pool/main/g/glibc/$LIBC_DEV_PKG"_*_"$(dpkg --print-architecture).deb"; then
	dpkg -i "$REPODIR/pool/main/g/glibc/$LIBC_DEV_PKG"_*_"$(dpkg --print-architecture).deb"
else
	cd /tmp/buildd
	apt-get download "$LIBC_DEV_PKG"
	dpkg-deb -R "./$LIBC_DEV_PKG"_*.deb x
	sed -i -e '/^Conflicts: /d' x/DEBIAN/control
	mv -nv -t x/usr/include "x/usr/include/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/"*
	mv -nv x/usr/include x/usr/include.orig
	mkdir x/usr/include
	mv -nv x/usr/include.orig "x/usr/include/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
	dpkg-deb -b x "./$LIBC_DEV_PKG"_*.deb
	reprepro includedeb rebootstrap-native "./$LIBC_DEV_PKG"_*.deb
	dpkg -i "./$LIBC_DEV_PKG"_*.deb
	$APT_GET update
	rm -R "./$LIBC_DEV_PKG"_*.deb x
fi # already repacked
fi # is glibc

chdist_native() {
	local command
	command="$1"
	shift
	chdist --data-dir /tmp/chdist_native --arch "$HOST_ARCH" "$command" native "$@"
}

if test "$ENABLE_DIFFOSCOPE" = yes; then
	$APT_GET install devscripts
	chdist_native create "$MIRROR" sid main
	if ! chdist_native apt-get update; then
		echo "rebootstrap-warning: not comparing packages to native builds"
		rm -Rf /tmp/chdist_native
		ENABLE_DIFFOSCOPE=no
	fi
fi
if test "$ENABLE_DIFFOSCOPE" = yes; then
	compare_native() {
		local pkg pkgname tmpdir downloadname errcode
		apt_get_install diffoscope binutils-multiarch vim-common
		for pkg in "$@"; do
			if test "`dpkg-deb -f "$pkg" Architecture`" != "$HOST_ARCH"; then
				echo "not comparing $pkg: wrong architecture"
				continue
			fi
			pkgname=`dpkg-deb -f "$pkg" Package`
			tmpdir=`mktemp -d`
			mkdir "$tmpdir/a" "$tmpdir/b"
			cp "$pkg" "$tmpdir/a" # work around diffoscope recursing over the build tree
			if ! (cd "$tmpdir/b" && chdist_native apt-get download "$pkgname"); then
				echo "not comparing $pkg: download failed"
				rm -R "$tmpdir"
				continue
			fi
			downloadname=`dpkg-deb -W --showformat '${Package}_${Version}_${Architecture}.deb' "$pkg" | sed 's/:/%3a/'`
			if ! test -f "$tmpdir/b/$downloadname"; then
				echo "not comparing $pkg: downloaded different version"
				rm -R "$tmpdir"
				continue
			fi
			errcode=0
			timeout --kill-after=1m 1h diffoscope --text "$tmpdir/out" "$tmpdir/a/$(basename -- "$pkg")" "$tmpdir/b/$downloadname" || errcode=$?
			case $errcode in
				0)
					echo "diffoscope-success: $pkg"
				;;
				1)
					if ! test -f "$tmpdir/out"; then
						echo "rebootstrap-error: no diffoscope output for $pkg"
						exit 1
					elif test "`wc -l < "$tmpdir/out"`" -gt 1000; then
						echo "truncated diffoscope output for $pkg:"
						head -n1000 "$tmpdir/out"
					else
						echo "diffoscope output for $pkg:"
						cat "$tmpdir/out"
					fi
				;;
				124)
					echo "rebootstrap-warning: diffoscope timed out"
				;;
				*)
					echo "rebootstrap-error: diffoscope terminated with abnormal exit code $errcode"
					exit 1
				;;
			esac
			rm -R "$tmpdir"
		done
	}
else
	compare_native() { :
	}
fi

pickup_additional_packages() {
	local f
	for f in "$@"; do
		if test "${f%.deb}" != "$f"; then
			reprepro includedeb rebootstrap "$f"
		elif test "${f%.changes}" != "$f"; then
			reprepro include rebootstrap "$f"
		else
			echo "cannot pick up package $f"
			exit 1
		fi
	done
	$APT_GET update
}

pickup_packages() {
	local sources
	local source
	local f
	local i
	# collect source package names referenced
	sources=""
	for f in "$@"; do
		if test "${f%.deb}" != "$f"; then
			source=`dpkg-deb -f "$f" Source`
			test -z "$source" && source=${f%%_*}
		elif test "${f%.changes}" != "$f"; then
			source=${f%%_*}
		else
			echo "cannot pick up package $f"
			exit 1
		fi
		sources=`set_add "$sources" "$source"`
	done
	# archive old contents and remove them from the repository
	for source in $sources; do
		i=1
		while test -e "$REPODIR/archive/${source}_$i"; do
			i=`expr $i + 1`
		done
		i="$REPODIR/archive/${source}_$i"
		mkdir "$i"
		for f in $(reprepro --list-format '${Filename}\n' listfilter rebootstrap "\$Source (== $source)"); do
			cp -v "$REPODIR/$f" "$i"
		done
		find "$i" -type d -empty -delete
		reprepro removesrc rebootstrap "$source"
	done
	# add new contents
	pickup_additional_packages "$@"
}

# compute a function name from a hook prefix $1 and a package name $2
# returns success if the function actually exists
get_hook() {
	local hook
	hook=`echo "$2" | tr -- -. __` # - and . are invalid in function names
	hook="${1}_$hook"
	echo "$hook"
	type "$hook" >/dev/null 2>&1 || return 1
}

cross_build_setup() {
	local pkg subdir hook
	pkg="$1"
	subdir="${2:-$pkg}"
	cd /tmp/buildd
	drop_privs mkdir "$subdir"
	cd "$subdir"
	obtain_source_package "$pkg"
	cd "${pkg}-"*
	hook=`get_hook patch "$pkg"` && "$hook"
	return 0
}

# add a binNMU changelog entry
# . is a debian package
# $1 is the binNMU number
# $2 is reason
add_binNMU_changelog() {
	cat - debian/changelog <<EOF |
$(dpkg-parsechangelog -SSource) ($(dpkg-parsechangelog -SVersion)+b$1) sid; urgency=medium, binary-only=yes

  * Binary-only non-maintainer upload for $HOST_ARCH; no source changes.
  * $2

 -- rebootstrap <invalid@invalid>  $(dpkg-parsechangelog -SDate)

EOF
		drop_privs tee debian/changelog.new >/dev/null
	drop_privs mv debian/changelog.new debian/changelog
}

check_binNMU() {
	local pkg srcversion binversion maxversion
	srcversion=`dpkg-parsechangelog -SVersion`
	maxversion=$srcversion
	for pkg in `dh_listpackages`; do
		binversion=`apt-cache show "$pkg=$srcversion*" 2>/dev/null | sed -n 's/^Version: //p;T;q'`
		test -z "$binversion" && continue
		if dpkg --compare-versions "$maxversion" lt "$binversion"; then
			maxversion=$binversion
		fi
	done
	case "$maxversion" in
		"$srcversion+b"*)
			echo "rebootstrap-warning: binNMU detected for $(dpkg-parsechangelog -SSource) $srcversion/$maxversion"
			add_binNMU_changelog "${maxversion#$srcversion+b}" "Bump to binNMU version of $(dpkg --print-architecture)."
		;;
	esac
}

PROGRESS_MARK=1
progress_mark() {
	echo "progress-mark:$PROGRESS_MARK:$*"
	PROGRESS_MARK=$(($PROGRESS_MARK + 1 ))
}

# prints the set (as in set_create) of installed packages
record_installed_packages() {
	dpkg --get-selections | sed 's/\s\+install$//;t;d' | xargs
}

# Takes the set (as in set_create) of packages and apt-get removes any
# currently installed packages outside the given set.
remove_extra_packages() {
	local origpackages currentpackages removedpackages extrapackages
	origpackages="$1"
	currentpackages=$(record_installed_packages)
	removedpackages=$(set_difference "$origpackages" "$currentpackages")
	extrapackages=$(set_difference "$currentpackages" "$origpackages")
	echo "original packages: $origpackages"
	echo "removed packages:  $removedpackages"
	echo "extra packages:    $extrapackages"
	apt_get_remove $extrapackages
}

buildpackage_failed() {
	local err last_config_log
	err="$1"
	echo "rebootstrap-error: dpkg-buildpackage failed with status $err"
	last_config_log=$(find . -type f -name config.log -printf "%T@ %p\n" | sort -g | tail -n1 | cut "-d " -f2-)
	if test -f "$last_config_log"; then
		tail -v -n+0 "$last_config_log"
	fi
	exit "$err"
}

cross_build() {
	local pkg profiles stamp ignorebd hook installedpackages
	pkg="$1"
	profiles="$DEFAULT_PROFILES ${2:-}"
	stamp="${3:-$pkg}"
	if test "$ENABLE_MULTILIB" = "no"; then
		profiles="$profiles nobiarch"
	fi
	profiles=`echo "$profiles" | sed 's/ /,/g;s/,,*/,/g;s/^,//;s/,$//'`
	if test -f "$REPODIR/stamps/$stamp"; then
		echo "skipping rebuild of $pkg with profiles $profiles"
	else
		echo "building $pkg with profiles $profiles"
		cross_build_setup "$pkg" "$stamp"
		installedpackages=$(record_installed_packages)
		if hook=`get_hook builddep "$pkg"`; then
			echo "installing Build-Depends for $pkg using custom function"
			"$hook" "$HOST_ARCH" "$profiles"
		else
			echo "installing Build-Depends for $pkg using apt-get build-dep"
			apt_get_build_dep "-a$HOST_ARCH" --arch-only -P "$profiles" ./
		fi
		check_binNMU
		ignorebd=
		if get_hook builddep "$pkg" >/dev/null; then
			if dpkg-checkbuilddeps -B "-a$HOST_ARCH" -P "$profiles"; then
				echo "rebootstrap-warning: Build-Depends for $pkg satisfied even though a custom builddep_  function is in use"
			fi
			ignorebd=-d
		fi
		(
			if hook=`get_hook buildenv "$pkg"`; then
				echo "adding environment variables via buildenv hook for $pkg"
				"$hook" "$HOST_ARCH"
			fi
			drop_privs_exec dpkg-buildpackage "-a$HOST_ARCH" -B "-P$profiles" $ignorebd -uc -us
		) || buildpackage_failed "$?"
		cd ..
		remove_extra_packages "$installedpackages"
		ls -l
		pickup_packages *.changes
		touch "$REPODIR/stamps/$stamp"
		compare_native ./*.deb
		cd ..
		drop_privs rm -Rf "$stamp"
	fi
	progress_mark "$stamp cross build"
}

case "$HOST_ARCH" in
	musl-linux-*) LIBC_NAME=musl ;;
esac

if test "$ENABLE_MULTIARCH_GCC" != yes; then
	apt_get_install dpkg-cross
fi

automatic_packages=
add_automatic() { automatic_packages=$(set_add "$automatic_packages" "$1"); }

add_automatic acl
add_automatic adns
add_automatic apt
add_automatic attr
add_automatic autogen
add_automatic base-files
add_automatic base-passwd
add_automatic bash

patch_binutils() {
	echo "patching binutils to discard ldscripts"
	# They cause file conflicts with binutils and the in-archive cross
	# binutils discard ldscripts as well.
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules
+++ b/debian/rules
@@ -751,6 +751,7 @@
 		mandir=$(pwd)/$(D_CROSS)/$(PF)/share/man install
 
 	rm -rf \
+		$(D_CROSS)/$(PF)/lib/ldscripts \
 		$(D_CROSS)/$(PF)/share/info \
 		$(D_CROSS)/$(PF)/share/locale
 
EOF
	if test "$HOST_ARCH" = hppa; then
		echo "patching binutils to discard hppa64 ldscripts"
		# They cause file conflicts with binutils and the in-archive
		# cross binutils discard ldscripts as well.
		drop_privs patch -p1 <<'EOF'
--- a/debian/rules
+++ b/debian/rules
@@ -1233,6 +1233,7 @@
 		$(d_hppa64)/$(PF)/lib/$(DEB_HOST_MULTIARCH)/.

 	: # Now get rid of just about everything in binutils-hppa64
+	rm -rf $(d_hppa64)/$(PF)/lib/ldscripts
 	rm -rf $(d_hppa64)/$(PF)/man
 	rm -rf $(d_hppa64)/$(PF)/info
 	rm -rf $(d_hppa64)/$(PF)/include
EOF
	fi
}

add_automatic blt
add_automatic bsdmainutils

builddep_build_essential() {
	# g++ dependency needs cross translation
	$APT_GET install debhelper python3
}

add_automatic bzip2
add_automatic c-ares
add_automatic coreutils
add_automatic curl

builddep_cyrus_sasl2() {
	assert_built "db-defaults db5.3 openssl pam"
	# many packages droppable in stage1
	$APT_GET install debhelper quilt automake autotools-dev "libdb-dev:$1" "libpam0g-dev:$1" "libssl-dev:$1" chrpath groff-base po-debconf docbook-to-man dh-autoreconf
}

add_automatic dash
add_automatic datefudge
add_automatic db-defaults
add_automatic debianutils

add_automatic diffutils
buildenv_diffutils() {
	if dpkg-architecture "-a$1" -ignu-any-any; then
		export gl_cv_func_getopt_gnu=yes
	fi
}

add_automatic dpkg
add_automatic e2fsprogs
add_automatic expat
add_automatic file
add_automatic findutils
add_automatic flex
add_automatic fontconfig
add_automatic freetype
add_automatic fribidi
add_automatic fuse

patch_gcc_default_pie_everywhere()
{
	echo "enabling pie everywhere #892281"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules.defs
+++ a/debian/rules.defs
@@ -1250,9 +1250,7 @@
     pie_archs += armhf arm64 i386
   endif
 endif
-ifneq (,$(filter $(DEB_TARGET_ARCH),$(pie_archs)))
-  with_pie := yes
-endif
+with_pie := yes
 ifeq ($(trunk_build),yes)
   with_pie := disabled for trunk builds
 endif
EOF
}
patch_gcc_limits_h_test() {
	echo "fix LIMITS_H_TEST again https://gcc.gnu.org/bugzilla/show_bug.cgi?id=80677"
	drop_privs sed -i -e 's,^\(+LIMITS_H_TEST = \).*,\1:,' debian/patches/gcc-multiarch.diff
}
patch_gcc_wdotap() {
	if test "$ENABLE_MULTIARCH_GCC" = yes; then
		echo "applying patches for with_deps_on_target_arch_pkgs"
		drop_privs rm -Rf .pc
		drop_privs QUILT_PATCHES="/usr/share/cross-gcc/patches/gcc-$GCC_VER" quilt push -a
		drop_privs rm -Rf .pc
	fi
}
patch_gcc_arc_matomic() {
	# -matomic not enabled in gcc driver, assumed by glibc
	if test "$HOST_ARCH" = arc; then
		echo "patching gcc: default to -mcpu=hs38"
		drop_privs patch -p1 <<'EOF'
--- /dev/null
+++ b/debian/patches/arc-hs38-default.diff
@@ -0,0 +1,18 @@
+#DP: build for hs38 as default
+
+---
+ gcc/config/arc/arc.h | 2 +-
+ 1 file changed, 1 insertion(+), 1 deletion(-)
+
+--- a/src/gcc/config/arc/arc.h
++++ b/src/gcc/config/arc/arc.h
+@@ -34,7 +34,7 @@ along with GCC; see the file COPYING3.  If not see
+ #define SYMBOL_FLAG_CMEM	(SYMBOL_FLAG_MACH_DEP << 3)
+ 
+ #ifndef TARGET_CPU_DEFAULT
+-#define TARGET_CPU_DEFAULT	PROCESSOR_arc700
++#define TARGET_CPU_DEFAULT	PROCESSOR_hs38_linux
+ #endif
+ 
+ /* Check if this symbol has a long_call attribute in its declaration */
+
diff --git a/debian/rules.patch b/debian/rules.patch
index afe17ea6a5ed..091ffe86622c 100644
--- a/debian/rules.patch
+++ b/debian/rules.patch
@@ -87,6 +87,7 @@ debian_patches += \
 	pr98274 \
 	pr97250-plugin-headers \
 	pr97714 \
+	arc-hs38-default \
 
 ifneq (,$(filter $(distrelease),wheezy jessie stretch buster lucid precise trusty xenial bionic cosmic disco eoan))
   debian_patches += pr85678-revert
EOF
	fi
}
patch_gcc_arc_multiarch() {
	# missing multiarch bits
	if test "$HOST_ARCH" = arc; then
		echo "patching gcc: define multiarch things"
		drop_privs patch -p1 <<'EOF'
--- /dev/null
+++ b/debian/patches/arc-gcc-multilib.diff
@@ -0,0 +1,21 @@
+#DP: define MULTIARCH_DIRNAME/MULTILIB_OSDIRNAMES
+
+---
+ gcc/config/arc/t-multilib-linux | 4 +++-
+ 1 file changed, 3 insertions(+), 1 deletion(-)
+
+--- a/src/gcc/config/arc/t-multilib-linux
++++ b/src/gcc/config/arc/t-multilib-linux
+@@ -17,9 +17,11 @@
+ # <http://www.gnu.org/licenses/>.
+ 
+ MULTILIB_OPTIONS = mcpu=hs/mcpu=archs/mcpu=hs38/mcpu=hs38_linux/mcpu=arc700/mcpu=nps400
+-
+ MULTILIB_DIRNAMES = hs archs hs38 hs38_linux arc700 nps400
+ 
++MULTILIB_OSDIRNAMES = ../lib$(call if_multiarch,:arc-linux-gnu)
++MULTIARCH_DIRNAME = $(call if_multiarch,arc-linux-gnu)
++
+ # Aliases:
+ MULTILIB_MATCHES += mcpu?arc700=mA7
+ MULTILIB_MATCHES += mcpu?arc700=mARC700
diff --git a/debian/rules.patch b/debian/rules.patch
index 091ffe86622c..080e2ed60203 100644
--- a/debian/rules.patch
+++ b/debian/rules.patch
@@ -88,6 +88,7 @@ debian_patches += \
 	pr97250-plugin-headers \
 	pr97714 \
 	arc-hs38-default \
+	arc-gcc-multilib \
 
 ifneq (,$(filter $(distrelease),wheezy jessie stretch buster lucid precise trusty xenial bionic cosmic disco eoan))
   debian_patches += pr85678-revert
EOF
	fi
}
patch_gcc_10() {
	patch_gcc_default_pie_everywhere
	patch_gcc_limits_h_test
	patch_gcc_wdotap
	patch_gcc_arc_matomic
	patch_gcc_arc_multiarch
}
patch_gcc_11() {
	patch_gcc_limits_h_test
	patch_gcc_wdotap
}

buildenv_gdbm() {
	if dpkg-architecture "-a$1" -ignu-any-any; then
		export ac_cv_func_mmap_fixed_mapped=yes
	fi
}

add_automatic glib2.0
buildenv_glib2_0() {
	export glib_cv_stack_grows=no
	export glib_cv_uscore=no
	export ac_cv_func_posix_getgrgid_r=yes
	export ac_cv_func_posix_getpwuid_r=yes
}

builddep_glibc() {
	test "$1" = "$HOST_ARCH"
	apt_get_install gettext file quilt autoconf gawk debhelper rdfind symlinks binutils bison netbase "gcc-$GCC_VER$HOST_ARCH_SUFFIX"
	case "$(dpkg-architecture "-a$1" -qDEB_HOST_ARCH_OS)" in
		linux)
			if test "$ENABLE_MULTIARCH_GCC" = yes; then
				apt_get_install "linux-libc-dev:$HOST_ARCH"
			else
				apt_get_install "linux-libc-dev-$HOST_ARCH-cross"
			fi
		;;
		hurd)
			apt_get_install "gnumach-dev:$1" "hurd-headers-dev:$1" "mig$HOST_ARCH_SUFFIX"
		;;
		*)
			echo "rebootstrap-error: unsupported kernel"
			exit 1
		;;
	esac
}
patch_glibc() {
	echo "patching glibc to pass -l to dh_shlibdeps for multilib"
	drop_privs patch -p1 <<'EOF'
diff -Nru glibc-2.19/debian/rules.d/debhelper.mk glibc-2.19/debian/rules.d/debhelper.mk
--- glibc-2.19/debian/rules.d/debhelper.mk
+++ glibc-2.19/debian/rules.d/debhelper.mk
@@ -109,7 +109,7 @@
 	./debian/shlibs-add-udebs $(curpass)
 
 	dh_installdeb -p$(curpass)
-	dh_shlibdeps -p$(curpass)
+	dh_shlibdeps $(if $($(lastword $(subst -, ,$(curpass)))_slibdir),-l$(CURDIR)/debian/$(curpass)/$($(lastword $(subst -, ,$(curpass)))_slibdir)) -p$(curpass)
 	dh_gencontrol -p$(curpass)
 	if [ $(curpass) = nscd ] ; then \
 		sed -i -e "s/\(Depends:.*libc[0-9.]\+\)-[a-z0-9]\+/\1/" debian/nscd/DEBIAN/control ; \
EOF
	echo "patching glibc to find standard linux headers"
	drop_privs patch -p1 <<'EOF'
diff -Nru glibc-2.19/debian/sysdeps/linux.mk glibc-2.19/debian/sysdeps/linux.mk
--- glibc-2.19/debian/sysdeps/linux.mk
+++ glibc-2.19/debian/sysdeps/linux.mk
@@ -16,7 +16,7 @@
 endif

 ifndef LINUX_SOURCE
-  ifeq ($(DEB_HOST_GNU_TYPE),$(DEB_BUILD_GNU_TYPE))
+  ifeq ($(shell dpkg-query --status linux-libc-dev-$(DEB_HOST_ARCH)-cross 2>/dev/null),)
     LINUX_HEADERS := /usr/include
   else
     LINUX_HEADERS := /usr/$(DEB_HOST_GNU_TYPE)/include
EOF
	if ! sed -n '/^libc6_archs *:=/,/[^\\]$/p' debian/rules.d/control.mk | grep -qw "$HOST_ARCH"; then
		echo "adding $HOST_ARCH to libc6_archs"
		drop_privs sed -i -e "s/^libc6_archs *:= /&$HOST_ARCH /" debian/rules.d/control.mk
		drop_privs ./debian/rules debian/control
	fi
	echo "patching glibc to drop dev package conflict"
	sed -i -e '/^Conflicts: @libc-dev-conflict@$/d' debian/control.in/libc
	echo "patching glibc to move all headers to multiarch locations #798955"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules.d/build.mk
+++ b/debian/rules.d/build.mk
@@ -4,12 +4,16 @@
 xx=$(if $($(curpass)_$(1)),$($(curpass)_$(1)),$($(1)))
 define generic_multilib_extra_pkg_install
 set -e; \
-mkdir -p debian/$(1)/usr/include/sys; \
-ln -sf $(DEB_HOST_MULTIARCH)/bits debian/$(1)/usr/include/; \
-ln -sf $(DEB_HOST_MULTIARCH)/gnu debian/$(1)/usr/include/; \
-ln -sf $(DEB_HOST_MULTIARCH)/fpu_control.h debian/$(1)/usr/include/; \
-for i in `ls debian/tmp-libc/usr/include/$(DEB_HOST_MULTIARCH)/sys`; do \
-	ln -sf ../$(DEB_HOST_MULTIARCH)/sys/$$i debian/$(1)/usr/include/sys/$$i; \
+mkdir -p debian/$(1)/usr/include; \
+for i in `ls debian/tmp-libc/usr/include/$(DEB_HOST_MULTIARCH)`; do \
+	if test -d "debian/tmp-libc/usr/include/$(DEB_HOST_MULTIARCH)/$$i" && ! test "$$i" = bits -o "$$i" = gnu; then \
+		mkdir -p "debian/$(1)/usr/include/$$i"; \
+		for j in `ls debian/tmp-libc/usr/include/$(DEB_HOST_MULTIARCH)/$$i`; do \
+			ln -sf "../$(DEB_HOST_MULTIARCH)/$$i/$$j" "debian/$(1)/usr/include/$$i/$$j"; \
+		done; \
+	else \
+		ln -sf "$(DEB_HOST_MULTIARCH)/$$i" "debian/$(1)/usr/include/$$i"; \
+	fi; \
 done
 endef
 
@@ -218,15 +218,11 @@
 	    echo "/lib/$(DEB_HOST_GNU_TYPE)" >> $$conffile; \
 	    echo "/usr/lib/$(DEB_HOST_GNU_TYPE)" >> $$conffile; \
 	  fi; \
-	  mkdir -p debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv debian/tmp-$(curpass)/usr/include/bits debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv debian/tmp-$(curpass)/usr/include/gnu debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv debian/tmp-$(curpass)/usr/include/sys debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv debian/tmp-$(curpass)/usr/include/fpu_control.h debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv debian/tmp-$(curpass)/usr/include/a.out.h debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH); \
-	  mv debian/tmp-$(curpass)/usr/include/ieee754.h debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH); \
+	  mkdir -p debian/tmp-$(curpass)/usr/include.tmp; \
+	  mv debian/tmp-$(curpass)/usr/include debian/tmp-$(curpass)/usr/include.tmp/$(DEB_HOST_MULTIARCH); \
+	  mv debian/tmp-$(curpass)/usr/include.tmp debian/tmp-$(curpass)/usr/include; \
 	  mkdir -p debian/tmp-$(curpass)/usr/include/finclude/$(DEB_HOST_MULTIARCH); \
-	  mv debian/tmp-$(curpass)/usr/include/finclude/math-vector-fortran.h debian/tmp-$(curpass)/usr/include/finclude/$(DEB_HOST_MULTIARCH); \
+	  mv debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH)/finclude/math-vector-fortran.h debian/tmp-$(curpass)/usr/include/finclude/$(DEB_HOST_MULTIARCH); \
 	fi
 
 	ifeq ($(filter stage1,$(DEB_BUILD_PROFILES)),)
--- a/debian/sysdeps/hurd-i386.mk
+++ b/debian/sysdeps/hurd-i386.mk
@@ -18,9 +18,6 @@ endif
 define libc_extra_install
 mkdir -p debian/tmp-$(curpass)/lib
 ln -s ld.so.1 debian/tmp-$(curpass)/lib/ld.so
-mkdir -p debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH)/mach
-mv debian/tmp-$(curpass)/usr/include/mach/i386 debian/tmp-$(curpass)/usr/include/$(DEB_HOST_MULTIARCH)/mach/
-ln -s ../$(DEB_HOST_MULTIARCH)/mach/i386 debian/tmp-$(curpass)/usr/include/mach/i386
 endef
 
 # FIXME: We are having runtime issues with ifunc...
EOF
	echo "patching glibc to avoid -Werror"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules.d/build.mk
+++ b/debian/rules.d/build.mk
@@ -85,6 +85,7 @@
 		$(CURDIR)/configure \
 		--host=$(call xx,configure_target) \
 		--build=$$configure_build --prefix=/usr \
+		--disable-werror \
 		--enable-add-ons=$(standard-add-ons)"$(call xx,add-ons)" \
 		--without-selinux \
 		--enable-stackguard-randomization \
EOF
	if test "$HOST_ARCH" = alpha; then
		echo "cherry-picking glibc alpha patch for struct stat"
		drop_privs patch -p1 <<'EOF'
From d552058570ea2c00fb88b4621be3285cda03033f Mon Sep 17 00:00:00 2001
From: Matt Turner <mattst88@gmail.com>
Date: Mon, 21 Dec 2020 09:09:43 -0300
Subject: [PATCH] alpha: Remove anonymous union in struct stat [BZ #27042]

This is clever, but it confuses downstream detection in at least zstd
and GNOME's glib. zstd has preprocessor tests for the 'st_mtime' macro,
which is not provided by the path using the anonymous union; glib checks
for the presence of 'st_mtimensec' in struct stat but then tries to
access that field in struct statx (which might be a bug on its own).

Checked with a build for alpha-linux-gnu.
---
 .../unix/sysv/linux/alpha/bits/struct_stat.h  | 81 ++++++++++---------
 sysdeps/unix/sysv/linux/alpha/kernel_stat.h   | 24 +++---
 sysdeps/unix/sysv/linux/alpha/xstatconv.c     | 24 +++---
 3 files changed, 66 insertions(+), 63 deletions(-)

diff --git a/sysdeps/unix/sysv/linux/alpha/bits/struct_stat.h b/sysdeps/unix/sysv/linux/alpha/bits/struct_stat.h
index 1c9b4248b8..d2aae9fdd7 100644
--- a/sysdeps/unix/sysv/linux/alpha/bits/stat.h
+++ b/sysdeps/unix/sysv/linux/alpha/bits/stat.h
@@ -23,37 +23,6 @@
 #ifndef _BITS_STRUCT_STAT_H
 #define _BITS_STRUCT_STAT_H	1

-/* Nanosecond resolution timestamps are stored in a format equivalent to
-   'struct timespec'.  This is the type used whenever possible but the
-   Unix namespace rules do not allow the identifier 'timespec' to appear
-   in the <sys/stat.h> header.  Therefore we have to handle the use of
-   this header in strictly standard-compliant sources special.
-
-   Use neat tidy anonymous unions and structures when possible.  */
-
-#ifdef __USE_XOPEN2K8
-# if __GNUC_PREREQ(3,3)
-#  define __ST_TIME(X)				\
-	__extension__ union {			\
-	    struct timespec st_##X##tim;	\
-	    struct {				\
-		__time_t st_##X##time;		\
-		unsigned long st_##X##timensec;	\
-	    };					\
-	}
-# else
-#  define __ST_TIME(X) struct timespec st_##X##tim
-#  define st_atime st_atim.tv_sec
-#  define st_mtime st_mtim.tv_sec
-#  define st_ctime st_ctim.tv_sec
-# endif
-#else
-# define __ST_TIME(X)				\
-	__time_t st_##X##time;			\
-	unsigned long st_##X##timensec
-#endif
-
-
 struct stat
   {
     __dev_t st_dev;		/* Device.  */
@@ -77,9 +46,27 @@ struct stat
     __blksize_t st_blksize;	/* Optimal block size for I/O.  */
     __nlink_t st_nlink;		/* Link count.  */
     int __pad2;			/* Real padding.  */
-    __ST_TIME(a);		/* Time of last access.  */
-    __ST_TIME(m);		/* Time of last modification.  */
-    __ST_TIME(c);		/* Time of last status change.  */
+#ifdef __USE_XOPEN2K8
+    /* Nanosecond resolution timestamps are stored in a format
+       equivalent to 'struct timespec'.  This is the type used
+       whenever possible but the Unix namespace rules do not allow the
+       identifier 'timespec' to appear in the <sys/stat.h> header.
+       Therefore we have to handle the use of this header in strictly
+       standard-compliant sources special.  */
+    struct timespec st_atim;		/* Time of last access.  */
+    struct timespec st_mtim;		/* Time of last modification.  */
+    struct timespec st_ctim;		/* Time of last status change.  */
+# define st_atime st_atim.tv_sec	/* Backward compatibility.  */
+# define st_mtime st_mtim.tv_sec
+# define st_ctime st_ctim.tv_sec
+#else
+    __time_t st_atime;			/* Time of last access.  */
+    unsigned long int st_atimensec;	/* Nscecs of last access.  */
+    __time_t st_mtime;			/* Time of last modification.  */
+    unsigned long int st_mtimensec;	/* Nsecs of last modification.  */
+    __time_t st_ctime;			/* Time of last status change.  */
+    unsigned long int st_ctimensec;	/* Nsecs of last status change.  */
+#endif
     long __glibc_reserved[3];
   };

@@ -98,15 +85,31 @@ struct stat64
     __blksize_t st_blksize;	/* Optimal block size for I/O.  */
     __nlink_t st_nlink;		/* Link count.  */
     int __pad0;			/* Real padding.  */
-    __ST_TIME(a);		/* Time of last access.  */
-    __ST_TIME(m);		/* Time of last modification.  */
-    __ST_TIME(c);		/* Time of last status change.  */
+#ifdef __USE_XOPEN2K8
+    /* Nanosecond resolution timestamps are stored in a format
+       equivalent to 'struct timespec'.  This is the type used
+       whenever possible but the Unix namespace rules do not allow the
+       identifier 'timespec' to appear in the <sys/stat.h> header.
+       Therefore we have to handle the use of this header in strictly
+       standard-compliant sources special.  */
+    struct timespec st_atim;		/* Time of last access.  */
+    struct timespec st_mtim;		/* Time of last modification.  */
+    struct timespec st_ctim;		/* Time of last status change.  */
+# define st_atime st_atim.tv_sec	/* Backward compatibility.  */
+# define st_mtime st_mtim.tv_sec
+# define st_ctime st_ctim.tv_sec
+#else
+    __time_t st_atime;			/* Time of last access.  */
+    unsigned long int st_atimensec;	/* Nscecs of last access.  */
+    __time_t st_mtime;			/* Time of last modification.  */
+    unsigned long int st_mtimensec;	/* Nsecs of last modification.  */
+    __time_t st_ctime;			/* Time of last status change.  */
+    unsigned long int st_ctimensec;	/* Nsecs of last status change.  */
+#endif
     long __glibc_reserved[3];
   };
 #endif

-#undef __ST_TIME
-
 /* Tell code we have these members.  */
 #define	_STATBUF_ST_BLKSIZE
 #define _STATBUF_ST_RDEV
diff --git a/sysdeps/unix/sysv/linux/alpha/kernel_stat.h b/sysdeps/unix/sysv/linux/alpha/kernel_stat.h
index ff69045f8f..a292920969 100644
--- a/sysdeps/unix/sysv/linux/alpha/kernel_stat.h
+++ b/sysdeps/unix/sysv/linux/alpha/kernel_stat.h
@@ -9,9 +9,9 @@ struct kernel_stat
     unsigned int st_gid;
     unsigned int st_rdev;
     long int st_size;
-    unsigned long int st_atime;
-    unsigned long int st_mtime;
-    unsigned long int st_ctime;
+    unsigned long int st_atime_sec;
+    unsigned long int st_mtime_sec;
+    unsigned long int st_ctime_sec;
     unsigned int st_blksize;
     int st_blocks;
     unsigned int st_flags;
@@ -34,11 +34,11 @@ struct kernel_stat64
     unsigned int    st_nlink;
     unsigned int    __pad0;

-    unsigned long   st_atime;
+    unsigned long   st_atime_sec;
     unsigned long   st_atimensec;
-    unsigned long   st_mtime;
+    unsigned long   st_mtime_sec;
     unsigned long   st_mtimensec;
-    unsigned long   st_ctime;
+    unsigned long   st_ctime_sec;
     unsigned long   st_ctimensec;
     long            __glibc_reserved[3];
   };
@@ -54,9 +54,9 @@ struct glibc2_stat
     __gid_t st_gid;
     __dev_t st_rdev;
     __off_t st_size;
-    __time_t st_atime;
-    __time_t st_mtime;
-    __time_t st_ctime;
+    __time_t st_atime_sec;
+    __time_t st_mtime_sec;
+    __time_t st_ctime_sec;
     unsigned int st_blksize;
     int st_blocks;
     unsigned int st_flags;
@@ -74,9 +74,9 @@ struct glibc21_stat
     __gid_t st_gid;
     __dev_t st_rdev;
     __off_t st_size;
-    __time_t st_atime;
-    __time_t st_mtime;
-    __time_t st_ctime;
+    __time_t st_atime_sec;
+    __time_t st_mtime_sec;
+    __time_t st_ctime_sec;
     __blkcnt64_t st_blocks;
     __blksize_t st_blksize;
     unsigned int st_flags;
diff --git a/sysdeps/unix/sysv/linux/alpha/xstatconv.c b/sysdeps/unix/sysv/linux/alpha/xstatconv.c
index f716a10f34..43224a7f25 100644
--- a/sysdeps/unix/sysv/linux/alpha/xstatconv.c
+++ b/sysdeps/unix/sysv/linux/alpha/xstatconv.c
@@ -44,9 +44,9 @@ __xstat_conv (int vers, struct kernel_stat *kbuf, void *ubuf)
 	buf->st_gid = kbuf->st_gid;
 	buf->st_rdev = kbuf->st_rdev;
 	buf->st_size = kbuf->st_size;
-	buf->st_atime = kbuf->st_atime;
-	buf->st_mtime = kbuf->st_mtime;
-	buf->st_ctime = kbuf->st_ctime;
+	buf->st_atime_sec = kbuf->st_atime_sec;
+	buf->st_mtime_sec = kbuf->st_mtime_sec;
+	buf->st_ctime_sec = kbuf->st_ctime_sec;
 	buf->st_blksize = kbuf->st_blksize;
 	buf->st_blocks = kbuf->st_blocks;
 	buf->st_flags = kbuf->st_flags;
@@ -66,9 +66,9 @@ __xstat_conv (int vers, struct kernel_stat *kbuf, void *ubuf)
 	buf->st_gid = kbuf->st_gid;
 	buf->st_rdev = kbuf->st_rdev;
 	buf->st_size = kbuf->st_size;
-	buf->st_atime = kbuf->st_atime;
-	buf->st_mtime = kbuf->st_mtime;
-	buf->st_ctime = kbuf->st_ctime;
+	buf->st_atime_sec = kbuf->st_atime_sec;
+	buf->st_mtime_sec = kbuf->st_mtime_sec;
+	buf->st_ctime_sec = kbuf->st_ctime_sec;
 	buf->st_blocks = kbuf->st_blocks;
 	buf->st_blksize = kbuf->st_blksize;
 	buf->st_flags = kbuf->st_flags;
@@ -98,12 +98,12 @@ __xstat_conv (int vers, struct kernel_stat *kbuf, void *ubuf)
 	buf->st_nlink = kbuf->st_nlink;
 	buf->__pad0 = 0;

-	buf->st_atime = kbuf->st_atime;
-	buf->st_atimensec = 0;
-	buf->st_mtime = kbuf->st_mtime;
-	buf->st_mtimensec = 0;
-	buf->st_ctime = kbuf->st_ctime;
-	buf->st_ctimensec = 0;
+	buf->st_atim.tv_sec = kbuf->st_atime_sec;
+	buf->st_atim.tv_nsec = 0;
+	buf->st_mtim.tv_sec = kbuf->st_mtime_sec;
+	buf->st_mtim.tv_nsec = 0;
+	buf->st_ctim.tv_sec = kbuf->st_ctime_sec;
+	buf->st_ctim.tv_nsec = 0;

 	buf->__glibc_reserved[0] = 0;
 	buf->__glibc_reserved[1] = 0;
EOF
	fi
	if test "$HOST_ARCH" = arc; then
		echo "patching glibc for arc glibc 2.31 port"
		drop_privs patch -p1 <<'EOF'
From 8f73a24d836503c03073259b445867cb7172d842 Mon Sep 17 00:00:00 2001
From: Vineet Gupta <vgupta@synopsys.com>
Date: Thu, 28 Mar 2019 15:24:35 -0700
Subject: [PATCH] ARC glibc 2.31 port

gcc PR 88409: miscompilation due to missing cc clobber in longlong.h macros
ARC: add definitions to elf/elf.h
ARC: ABI Implementation
ARC: startup and dynamic linking code
ARC: Thread Local Storage support
ARC: Atomics and Locking primitives
ARC: math soft float support
ARC: hardware floating point support
ARC: Linux Syscall Interface
ARC: Linux ABI
ARC: Linux Startup and Dynamic Loading
ARC: ABI lists
ARC: Update syscall-names.list for ARC specific syscalls
ARC: Build Infrastructure

Signed-off-by: Vineet Gupta <vgupta@synopsys.com>
---
 elf/elf.h                                     |   70 +-
 stdlib/longlong.h                             |    6 +-
 sysdeps/arc/Implies                           |    4 +
 sysdeps/arc/Makefile                          |   25 +
 sysdeps/arc/Versions                          |    6 +
 sysdeps/arc/__longjmp.S                       |   50 +
 sysdeps/arc/abort-instr.h                     |    2 +
 sysdeps/arc/atomic-machine.h                  |   73 +
 sysdeps/arc/bits/endianness.h                 |   15 +
 sysdeps/arc/bits/fenv.h                       |   77 +
 sysdeps/arc/bits/link.h                       |   52 +
 sysdeps/arc/bits/setjmp.h                     |   26 +
 sysdeps/arc/bsd-_setjmp.S                     |    1 +
 sysdeps/arc/bsd-setjmp.S                      |    1 +
 sysdeps/arc/configure                         |   14 +
 sysdeps/arc/configure.ac                      |   11 +
 sysdeps/arc/dl-machine.h                      |  340 +++
 sysdeps/arc/dl-runtime.c                      |   39 +
 sysdeps/arc/dl-sysdep.h                       |   25 +
 sysdeps/arc/dl-tls.h                          |   30 +
 sysdeps/arc/dl-trampoline.S                   |   80 +
 sysdeps/arc/entry.h                           |    5 +
 sysdeps/arc/fpu/e_sqrt.c                      |   26 +
 sysdeps/arc/fpu/e_sqrtf.c                     |   26 +
 sysdeps/arc/fpu/fclrexcpt.c                   |   36 +
 sysdeps/arc/fpu/fegetenv.c                    |   37 +
 sysdeps/arc/fpu/fegetmode.c                   |   31 +
 sysdeps/arc/fpu/fegetround.c                  |   32 +
 sysdeps/arc/fpu/feholdexcpt.c                 |   43 +
 sysdeps/arc/fpu/fesetenv.c                    |   48 +
 sysdeps/arc/fpu/fesetexcept.c                 |   32 +
 sysdeps/arc/fpu/fesetmode.c                   |   41 +
 sysdeps/arc/fpu/fesetround.c                  |   39 +
 sysdeps/arc/fpu/feupdateenv.c                 |   46 +
 sysdeps/arc/fpu/fgetexcptflg.c                |   31 +
 sysdeps/arc/fpu/fraiseexcpt.c                 |   39 +
 sysdeps/arc/fpu/fsetexcptflg.c                |   38 +
 sysdeps/arc/fpu/ftestexcept.c                 |   33 +
 sysdeps/arc/fpu/libm-test-ulps                | 1703 ++++++++++++++
 sysdeps/arc/fpu/libm-test-ulps-name           |    1 +
 sysdeps/arc/fpu/s_fma.c                       |   28 +
 sysdeps/arc/fpu/s_fmaf.c                      |   28 +
 sysdeps/arc/fpu_control.h                     |  101 +
 sysdeps/arc/gccframe.h                        |   21 +
 sysdeps/arc/get-rounding-mode.h               |   38 +
 sysdeps/arc/gmp-mparam.h                      |   23 +
 sysdeps/arc/jmpbuf-offsets.h                  |   47 +
 sysdeps/arc/jmpbuf-unwind.h                   |   47 +
 sysdeps/arc/ldsodefs.h                        |   43 +
 sysdeps/arc/libc-tls.c                        |   27 +
 sysdeps/arc/machine-gmon.h                    |   35 +
 sysdeps/arc/math-tests-trap.h                 |   27 +
 sysdeps/arc/memusage.h                        |   23 +
 sysdeps/arc/nofpu/Implies                     |    1 +
 sysdeps/arc/nofpu/libm-test-ulps              |  390 +++
 sysdeps/arc/nofpu/libm-test-ulps-name         |    1 +
 sysdeps/arc/nofpu/math-tests-exceptions.h     |   27 +
 sysdeps/arc/nofpu/math-tests-rounding.h       |   27 +
 sysdeps/arc/nptl/Makefile                     |   22 +
 sysdeps/arc/nptl/bits/semaphore.h             |   32 +
 sysdeps/arc/nptl/pthreaddef.h                 |   32 +
 sysdeps/arc/nptl/tcb-offsets.sym              |   11 +
 sysdeps/arc/nptl/tls.h                        |  150 ++
 sysdeps/arc/preconfigure                      |   15 +
 sysdeps/arc/setjmp.S                          |   66 +
 sysdeps/arc/sfp-machine.h                     |   73 +
 sysdeps/arc/sotruss-lib.c                     |   51 +
 sysdeps/arc/stackinfo.h                       |   33 +
 sysdeps/arc/start.S                           |   71 +
 sysdeps/arc/sysdep.h                          |   48 +
 sysdeps/arc/tininess.h                        |    1 +
 sysdeps/arc/tls-macros.h                      |   47 +
 sysdeps/arc/tst-audit.h                       |   23 +
 sysdeps/unix/sysv/linux/arc/Implies           |    3 +
 sysdeps/unix/sysv/linux/arc/Makefile          |   20 +
 sysdeps/unix/sysv/linux/arc/Versions          |   16 +
 sysdeps/unix/sysv/linux/arc/arch-syscall.h    |  317 +++
 sysdeps/unix/sysv/linux/arc/bits/procfs.h     |   35 +
 .../sysv/linux/arc/bits/types/__sigset_t.h    |   12 +
 sysdeps/unix/sysv/linux/arc/c++-types.data    |   67 +
 sysdeps/unix/sysv/linux/arc/clone.S           |   98 +
 sysdeps/unix/sysv/linux/arc/configure         |    4 +
 sysdeps/unix/sysv/linux/arc/configure.ac      |    4 +
 sysdeps/unix/sysv/linux/arc/dl-static.c       |   84 +
 sysdeps/unix/sysv/linux/arc/getcontext.S      |   63 +
 sysdeps/unix/sysv/linux/arc/jmp_buf-macros.h  |    6 +
 sysdeps/unix/sysv/linux/arc/kernel-features.h |   28 +
 sysdeps/unix/sysv/linux/arc/ld.abilist        |    9 +
 sysdeps/unix/sysv/linux/arc/ldsodefs.h        |   32 +
 .../sysv/linux/arc/libBrokenLocale.abilist    |    1 +
 sysdeps/unix/sysv/linux/arc/libanl.abilist    |    4 +
 sysdeps/unix/sysv/linux/arc/libc.abilist      | 2084 +++++++++++++++++
 sysdeps/unix/sysv/linux/arc/libcrypt.abilist  |    2 +
 sysdeps/unix/sysv/linux/arc/libdl.abilist     |    9 +
 sysdeps/unix/sysv/linux/arc/libm.abilist      |  765 ++++++
 .../unix/sysv/linux/arc/libpthread.abilist    |  227 ++
 sysdeps/unix/sysv/linux/arc/libresolv.abilist |   79 +
 sysdeps/unix/sysv/linux/arc/librt.abilist     |   35 +
 .../unix/sysv/linux/arc/libthread_db.abilist  |   40 +
 sysdeps/unix/sysv/linux/arc/libutil.abilist   |    6 +
 sysdeps/unix/sysv/linux/arc/localplt.data     |   16 +
 sysdeps/unix/sysv/linux/arc/makecontext.c     |   75 +
 sysdeps/unix/sysv/linux/arc/mmap_internal.h   |   27 +
 sysdeps/unix/sysv/linux/arc/pt-vfork.S        |    1 +
 sysdeps/unix/sysv/linux/arc/setcontext.S      |   92 +
 sysdeps/unix/sysv/linux/arc/shlib-versions    |    2 +
 sysdeps/unix/sysv/linux/arc/sigaction.c       |   31 +
 sysdeps/unix/sysv/linux/arc/sigcontextinfo.h  |   28 +
 sysdeps/unix/sysv/linux/arc/sigrestorer.S     |   29 +
 sysdeps/unix/sysv/linux/arc/swapcontext.S     |   92 +
 sysdeps/unix/sysv/linux/arc/sys/cachectl.h    |   36 +
 sysdeps/unix/sysv/linux/arc/sys/ucontext.h    |   63 +
 sysdeps/unix/sysv/linux/arc/sys/user.h        |   31 +
 sysdeps/unix/sysv/linux/arc/syscall.S         |   38 +
 sysdeps/unix/sysv/linux/arc/syscalls.list     |    3 +
 sysdeps/unix/sysv/linux/arc/sysdep.c          |   33 +
 sysdeps/unix/sysv/linux/arc/sysdep.h          |  250 ++
 sysdeps/unix/sysv/linux/arc/ucontext-macros.h |   29 +
 sysdeps/unix/sysv/linux/arc/ucontext_i.sym    |   20 +
 sysdeps/unix/sysv/linux/arc/vfork.S           |   42 +
 sysdeps/unix/sysv/linux/syscall-names.list    |    3 +
 121 files changed, 9831 insertions(+), 3 deletions(-)
 create mode 100644 sysdeps/arc/Implies
 create mode 100644 sysdeps/arc/Makefile
 create mode 100644 sysdeps/arc/Versions
 create mode 100644 sysdeps/arc/__longjmp.S
 create mode 100644 sysdeps/arc/abort-instr.h
 create mode 100644 sysdeps/arc/atomic-machine.h
 create mode 100644 sysdeps/arc/bits/endianness.h
 create mode 100644 sysdeps/arc/bits/fenv.h
 create mode 100644 sysdeps/arc/bits/link.h
 create mode 100644 sysdeps/arc/bits/setjmp.h
 create mode 100644 sysdeps/arc/bsd-_setjmp.S
 create mode 100644 sysdeps/arc/bsd-setjmp.S
 create mode 100644 sysdeps/arc/configure
 create mode 100644 sysdeps/arc/configure.ac
 create mode 100644 sysdeps/arc/dl-machine.h
 create mode 100644 sysdeps/arc/dl-runtime.c
 create mode 100644 sysdeps/arc/dl-sysdep.h
 create mode 100644 sysdeps/arc/dl-tls.h
 create mode 100644 sysdeps/arc/dl-trampoline.S
 create mode 100644 sysdeps/arc/entry.h
 create mode 100644 sysdeps/arc/fpu/e_sqrt.c
 create mode 100644 sysdeps/arc/fpu/e_sqrtf.c
 create mode 100644 sysdeps/arc/fpu/fclrexcpt.c
 create mode 100644 sysdeps/arc/fpu/fegetenv.c
 create mode 100644 sysdeps/arc/fpu/fegetmode.c
 create mode 100644 sysdeps/arc/fpu/fegetround.c
 create mode 100644 sysdeps/arc/fpu/feholdexcpt.c
 create mode 100644 sysdeps/arc/fpu/fesetenv.c
 create mode 100644 sysdeps/arc/fpu/fesetexcept.c
 create mode 100644 sysdeps/arc/fpu/fesetmode.c
 create mode 100644 sysdeps/arc/fpu/fesetround.c
 create mode 100644 sysdeps/arc/fpu/feupdateenv.c
 create mode 100644 sysdeps/arc/fpu/fgetexcptflg.c
 create mode 100644 sysdeps/arc/fpu/fraiseexcpt.c
 create mode 100644 sysdeps/arc/fpu/fsetexcptflg.c
 create mode 100644 sysdeps/arc/fpu/ftestexcept.c
 create mode 100644 sysdeps/arc/fpu/libm-test-ulps
 create mode 100644 sysdeps/arc/fpu/libm-test-ulps-name
 create mode 100644 sysdeps/arc/fpu/s_fma.c
 create mode 100644 sysdeps/arc/fpu/s_fmaf.c
 create mode 100644 sysdeps/arc/fpu_control.h
 create mode 100644 sysdeps/arc/gccframe.h
 create mode 100644 sysdeps/arc/get-rounding-mode.h
 create mode 100644 sysdeps/arc/gmp-mparam.h
 create mode 100644 sysdeps/arc/jmpbuf-offsets.h
 create mode 100644 sysdeps/arc/jmpbuf-unwind.h
 create mode 100644 sysdeps/arc/ldsodefs.h
 create mode 100644 sysdeps/arc/libc-tls.c
 create mode 100644 sysdeps/arc/machine-gmon.h
 create mode 100644 sysdeps/arc/math-tests-trap.h
 create mode 100644 sysdeps/arc/memusage.h
 create mode 100644 sysdeps/arc/nofpu/Implies
 create mode 100644 sysdeps/arc/nofpu/libm-test-ulps
 create mode 100644 sysdeps/arc/nofpu/libm-test-ulps-name
 create mode 100644 sysdeps/arc/nofpu/math-tests-exceptions.h
 create mode 100644 sysdeps/arc/nofpu/math-tests-rounding.h
 create mode 100644 sysdeps/arc/nptl/Makefile
 create mode 100644 sysdeps/arc/nptl/bits/semaphore.h
 create mode 100644 sysdeps/arc/nptl/pthreaddef.h
 create mode 100644 sysdeps/arc/nptl/tcb-offsets.sym
 create mode 100644 sysdeps/arc/nptl/tls.h
 create mode 100644 sysdeps/arc/preconfigure
 create mode 100644 sysdeps/arc/setjmp.S
 create mode 100644 sysdeps/arc/sfp-machine.h
 create mode 100644 sysdeps/arc/sotruss-lib.c
 create mode 100644 sysdeps/arc/stackinfo.h
 create mode 100644 sysdeps/arc/start.S
 create mode 100644 sysdeps/arc/sysdep.h
 create mode 100644 sysdeps/arc/tininess.h
 create mode 100644 sysdeps/arc/tls-macros.h
 create mode 100644 sysdeps/arc/tst-audit.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/Implies
 create mode 100644 sysdeps/unix/sysv/linux/arc/Makefile
 create mode 100644 sysdeps/unix/sysv/linux/arc/Versions
 create mode 100644 sysdeps/unix/sysv/linux/arc/arch-syscall.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/bits/procfs.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/bits/types/__sigset_t.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/c++-types.data
 create mode 100644 sysdeps/unix/sysv/linux/arc/clone.S
 create mode 100644 sysdeps/unix/sysv/linux/arc/configure
 create mode 100644 sysdeps/unix/sysv/linux/arc/configure.ac
 create mode 100644 sysdeps/unix/sysv/linux/arc/dl-static.c
 create mode 100644 sysdeps/unix/sysv/linux/arc/getcontext.S
 create mode 100644 sysdeps/unix/sysv/linux/arc/jmp_buf-macros.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/kernel-features.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/ld.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/ldsodefs.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/libBrokenLocale.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libanl.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libc.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libcrypt.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libdl.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libm.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libpthread.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libresolv.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/librt.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libthread_db.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/libutil.abilist
 create mode 100644 sysdeps/unix/sysv/linux/arc/localplt.data
 create mode 100644 sysdeps/unix/sysv/linux/arc/makecontext.c
 create mode 100644 sysdeps/unix/sysv/linux/arc/mmap_internal.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/pt-vfork.S
 create mode 100644 sysdeps/unix/sysv/linux/arc/setcontext.S
 create mode 100644 sysdeps/unix/sysv/linux/arc/shlib-versions
 create mode 100644 sysdeps/unix/sysv/linux/arc/sigaction.c
 create mode 100644 sysdeps/unix/sysv/linux/arc/sigcontextinfo.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/sigrestorer.S
 create mode 100644 sysdeps/unix/sysv/linux/arc/swapcontext.S
 create mode 100644 sysdeps/unix/sysv/linux/arc/sys/cachectl.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/sys/ucontext.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/sys/user.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/syscall.S
 create mode 100644 sysdeps/unix/sysv/linux/arc/syscalls.list
 create mode 100644 sysdeps/unix/sysv/linux/arc/sysdep.c
 create mode 100644 sysdeps/unix/sysv/linux/arc/sysdep.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/ucontext-macros.h
 create mode 100644 sysdeps/unix/sysv/linux/arc/ucontext_i.sym
 create mode 100644 sysdeps/unix/sysv/linux/arc/vfork.S

diff --git a/elf/elf.h b/elf/elf.h
index 2549a177d6ea..1d235cf3acca 100644
--- a/elf/elf.h
+++ b/elf/elf.h
@@ -330,7 +330,7 @@ typedef struct
 #define EM_CLOUDSHIELD	192	/* CloudShield */
 #define EM_COREA_1ST	193	/* KIPO-KAIST Core-A 1st gen. */
 #define EM_COREA_2ND	194	/* KIPO-KAIST Core-A 2nd gen. */
-#define EM_ARC_COMPACT2	195	/* Synopsys ARCompact V2 */
+#define EM_ARCV2	195	/* Synopsys ARCv2 ISA.  */
 #define EM_OPEN8	196	/* Open8 RISC */
 #define EM_RL78		197	/* Renesas RL78 */
 #define EM_VIDEOCORE5	198	/* Broadcom VideoCore V */
@@ -4027,6 +4027,74 @@ enum
 #define R_NDS32_TLS_TPOFF	102
 #define R_NDS32_TLS_DESC	119
 
+/* ARCompact/ARCv2 specific relocs.  */
+#define R_ARC_NONE		0x0
+#define R_ARC_8			0x1
+#define R_ARC_16		0x2
+#define R_ARC_24		0x3
+#define R_ARC_32		0x4
+#define R_ARC_B26		0x5
+#define R_ARC_B22_PCREL		0x6
+#define R_ARC_H30		0x7
+#define R_ARC_N8		0x8
+#define R_ARC_N16		0x9
+#define R_ARC_N24		0xA
+#define R_ARC_N32		0xB
+#define R_ARC_SDA		0xC
+#define R_ARC_SECTOFF		0xD
+#define R_ARC_S21H_PCREL	0xE
+#define R_ARC_S21W_PCREL	0xF
+#define R_ARC_S25H_PCREL	0x10
+#define R_ARC_S25W_PCREL	0x11
+#define R_ARC_SDA32		0x12
+#define R_ARC_SDA_LDST		0x13
+#define R_ARC_SDA_LDST1		0x14
+#define R_ARC_SDA_LDST2		0x15
+#define R_ARC_SDA16_LD		0x16
+#define R_ARC_SDA16_LD1		0x17
+#define R_ARC_SDA16_LD2		0x18
+#define R_ARC_S13_PCREL		0x19
+#define R_ARC_W			0x1A
+#define R_ARC_32_ME		0x1B
+#define R_ARC_N32_ME		0x1C
+#define R_ARC_SECTOFF_ME	0x1D
+#define R_ARC_SDA32_ME		0x1E
+#define R_ARC_W_ME		0x1F
+#define R_ARC_H30_ME		0x20
+#define R_ARC_SECTOFF_U8	0x21
+#define R_ARC_SECTOFF_S9	0x22
+#define R_AC_SECTOFF_U8		0x23
+#define R_AC_SECTOFF_U8_1	0x24
+#define R_AC_SECTOFF_U8_2	0x25
+#define R_AC_SECTOFF_S9		0x26
+#define R_AC_SECTOFF_S9_1	0x27
+#define R_AC_SECTOFF_S9_2	0x28
+#define R_ARC_SECTOFF_ME_1	0x29
+#define R_ARC_SECTOFF_ME_2	0x2A
+#define R_ARC_SECTOFF_1		0x2B
+#define R_ARC_SECTOFF_2		0x2C
+#define R_ARC_PC32		0x32
+#define R_ARC_GOTPC32		0x33
+#define R_ARC_PLT32		0x34
+#define R_ARC_COPY		0x35
+#define R_ARC_GLOB_DAT		0x36
+#define R_ARC_JUMP_SLOT		0x37
+#define R_ARC_RELATIVE		0x38
+#define R_ARC_GOTOFF		0x39
+#define R_ARC_GOTPC		0x3A
+#define R_ARC_GOT32		0x3B
+
+#define R_ARC_TLS_DTPMOD	0x42
+#define R_ARC_TLS_DTPOFF	0x43
+#define R_ARC_TLS_TPOFF		0x44
+#define R_ARC_TLS_GD_GOT	0x45
+#define R_ARC_TLS_GD_LD	        0x46
+#define R_ARC_TLS_GD_CALL	0x47
+#define R_ARC_TLS_IE_GOT	0x48
+#define R_ARC_TLS_DTPOFF_S9	0x4a
+#define R_ARC_TLS_LE_S9		0x4a
+#define R_ARC_TLS_LE_32		0x4b
+
 __END_DECLS
 
 #endif	/* elf.h */
diff --git a/stdlib/longlong.h b/stdlib/longlong.h
index ee4aac1bb5a0..638b7894d48c 100644
--- a/stdlib/longlong.h
+++ b/stdlib/longlong.h
@@ -199,7 +199,8 @@ extern UDItype __udiv_qrnnd (UDItype *, UDItype, UDItype, UDItype);
 	   : "%r" ((USItype) (ah)),					\
 	     "rICal" ((USItype) (bh)),					\
 	     "%r" ((USItype) (al)),					\
-	     "rICal" ((USItype) (bl)))
+	     "rICal" ((USItype) (bl))					\
+	   : "cc")
 #define sub_ddmmss(sh, sl, ah, al, bh, bl) \
   __asm__ ("sub.f	%1, %4, %5\n\tsbc	%0, %2, %3"		\
 	   : "=r" ((USItype) (sh)),					\
@@ -207,7 +208,8 @@ extern UDItype __udiv_qrnnd (UDItype *, UDItype, UDItype, UDItype);
 	   : "r" ((USItype) (ah)),					\
 	     "rICal" ((USItype) (bh)),					\
 	     "r" ((USItype) (al)),					\
-	     "rICal" ((USItype) (bl)))
+	     "rICal" ((USItype) (bl))					\
+	   : "cc")
 
 #define __umulsidi3(u,v) ((UDItype)(USItype)u*(USItype)v)
 #ifdef __ARC_NORM__
diff --git a/sysdeps/arc/Implies b/sysdeps/arc/Implies
new file mode 100644
index 000000000000..a0f0b00cfac2
--- /dev/null
+++ b/sysdeps/arc/Implies
@@ -0,0 +1,4 @@
+init_array
+wordsize-32
+ieee754/flt-32
+ieee754/dbl-64
diff --git a/sysdeps/arc/Makefile b/sysdeps/arc/Makefile
new file mode 100644
index 000000000000..92f90798355b
--- /dev/null
+++ b/sysdeps/arc/Makefile
@@ -0,0 +1,25 @@
+# ARC Makefile
+# Copyright (C) 1993-2020 Free Software Foundation, Inc.
+# This file is part of the GNU C Library.
+
+# The GNU C Library is free software; you can redistribute it and/or
+# modify it under the terms of the GNU Lesser General Public
+# License as published by the Free Software Foundation; either
+# version 2.1 of the License, or (at your option) any later version.
+
+# The GNU C Library is distributed in the hope that it will be useful,
+# but WITHOUT ANY WARRANTY; without even the implied warranty of
+# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+# Lesser General Public License for more details.
+
+# You should have received a copy of the GNU Lesser General Public
+# License along with the GNU C Library.  If not, see
+# <https://www.gnu.org/licenses/>.
+
+# We don't support long doubles as a distinct type.  We don't need to set
+# this variable; it's here mostly for documentational purposes.
+long-double-fcts = no
+
+ifeq ($(subdir),debug)
+CFLAGS-backtrace.c += -funwind-tables
+endif
diff --git a/sysdeps/arc/Versions b/sysdeps/arc/Versions
new file mode 100644
index 000000000000..2d0f534b2aba
--- /dev/null
+++ b/sysdeps/arc/Versions
@@ -0,0 +1,6 @@
+libc {
+  GLIBC_2.32 {
+    __syscall_error;
+    __mcount;
+  }
+}
diff --git a/sysdeps/arc/__longjmp.S b/sysdeps/arc/__longjmp.S
new file mode 100644
index 000000000000..ffc3daa7de72
--- /dev/null
+++ b/sysdeps/arc/__longjmp.S
@@ -0,0 +1,50 @@
+/* longjmp for ARC.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public License as
+   published by the Free Software Foundation; either version 2.1 of the
+   License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sysdep.h>
+#include <jmpbuf-offsets.h>
+
+;@ r0 = jump buffer from which regs will be restored
+;@ r1 = value that setjmp( ) will return due to this longjmp
+
+ENTRY (__longjmp)
+
+	ld_s r13,   [r0]
+	ld_s r14,   [r0,4]
+	ld   r15,   [r0,8]
+	ld   r16,   [r0,12]
+	ld   r17,   [r0,16]
+	ld   r18,   [r0,20]
+	ld   r19,   [r0,24]
+	ld   r20,   [r0,28]
+	ld   r21,   [r0,32]
+	ld   r22,   [r0,36]
+	ld   r23,   [r0,40]
+	ld   r24,   [r0,44]
+	ld   r25,   [r0,48]
+
+	ld   blink, [r0,60]
+	ld   fp,    [r0,52]
+	ld   sp,    [r0,56]
+
+	mov.f  r0, r1	; get the setjmp return value(due to longjmp) in place
+
+	j.d    [blink]	; to caller of setjmp location, right after the call
+	mov.z  r0, 1	; can't let setjmp return 0 when it is due to longjmp
+
+END (__longjmp)
diff --git a/sysdeps/arc/abort-instr.h b/sysdeps/arc/abort-instr.h
new file mode 100644
index 000000000000..49f33613c404
--- /dev/null
+++ b/sysdeps/arc/abort-instr.h
@@ -0,0 +1,2 @@
+/* FLAG 1 is privilege mode only instruction, hence will crash any program.  */
+#define ABORT_INSTRUCTION asm ("flag 1")
diff --git a/sysdeps/arc/atomic-machine.h b/sysdeps/arc/atomic-machine.h
new file mode 100644
index 000000000000..ae16c607dcc4
--- /dev/null
+++ b/sysdeps/arc/atomic-machine.h
@@ -0,0 +1,73 @@
+/* Low-level functions for atomic operations. ARC version.
+   Copyright (C) 2012-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _ARC_BITS_ATOMIC_H
+#define _ARC_BITS_ATOMIC_H 1
+
+#include <stdint.h>
+
+typedef int32_t atomic32_t;
+typedef uint32_t uatomic32_t;
+typedef int_fast32_t atomic_fast32_t;
+typedef uint_fast32_t uatomic_fast32_t;
+
+typedef intptr_t atomicptr_t;
+typedef uintptr_t uatomicptr_t;
+typedef intmax_t atomic_max_t;
+typedef uintmax_t uatomic_max_t;
+
+#define __HAVE_64B_ATOMICS 0
+#define USE_ATOMIC_COMPILER_BUILTINS 1
+
+/* ARC does have legacy atomic EX reg, [mem] instruction but the micro-arch
+   is not as optimal as LLOCK/SCOND specially for SMP.  */
+#define ATOMIC_EXCHANGE_USES_CAS 1
+
+#define __arch_compare_and_exchange_bool_8_acq(mem, newval, oldval)	\
+  (abort (), 0)
+#define __arch_compare_and_exchange_bool_16_acq(mem, newval, oldval)	\
+  (abort (), 0)
+#define __arch_compare_and_exchange_bool_64_acq(mem, newval, oldval)	\
+  (abort (), 0)
+
+#define __arch_compare_and_exchange_val_8_int(mem, newval, oldval, model)	\
+  (abort (), (__typeof (*mem)) 0)
+#define __arch_compare_and_exchange_val_16_int(mem, newval, oldval, model)	\
+  (abort (), (__typeof (*mem)) 0)
+#define __arch_compare_and_exchange_val_64_int(mem, newval, oldval, model)	\
+  (abort (), (__typeof (*mem)) 0)
+
+#define __arch_compare_and_exchange_val_32_int(mem, newval, oldval, model)	\
+  ({										\
+    typeof (*mem) __oldval = (oldval);                                  	\
+    __atomic_compare_exchange_n (mem, (void *) &__oldval, newval, 0,    	\
+                                 model, __ATOMIC_RELAXED);              	\
+    __oldval;                                                           	\
+  })
+
+#define atomic_compare_and_exchange_val_acq(mem, new, old)		\
+  __atomic_val_bysize (__arch_compare_and_exchange_val, int,		\
+		       mem, new, old, __ATOMIC_ACQUIRE)
+
+#ifdef __ARC700__
+#define atomic_full_barrier()  ({ asm volatile ("sync":::"memory"); })
+#else
+#define atomic_full_barrier()  ({ asm volatile ("dmb 3":::"memory"); })
+#endif
+
+#endif /* _ARC_BITS_ATOMIC_H */
diff --git a/sysdeps/arc/bits/endianness.h b/sysdeps/arc/bits/endianness.h
new file mode 100644
index 000000000000..8f17ca84b485
--- /dev/null
+++ b/sysdeps/arc/bits/endianness.h
@@ -0,0 +1,15 @@
+#ifndef _BITS_ENDIANNESS_H
+#define _BITS_ENDIANNESS_H 1
+
+#ifndef _BITS_ENDIAN_H
+# error "Never use <bits/endian.h> directly; include <endian.h> instead."
+#endif
+
+/* ARC has selectable endianness.  */
+#ifdef __BIG_ENDIAN__
+# define __BYTE_ORDER __BIG_ENDIAN
+#else
+# define __BYTE_ORDER __LITTLE_ENDIAN
+#endif
+
+#endif /* bits/endianness.h */
diff --git a/sysdeps/arc/bits/fenv.h b/sysdeps/arc/bits/fenv.h
new file mode 100644
index 000000000000..80afa50db9c6
--- /dev/null
+++ b/sysdeps/arc/bits/fenv.h
@@ -0,0 +1,77 @@
+/* Copyright (C) 2012-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _FENV_H
+# error "Never use <bits/fenv.h> directly; include <fenv.h> instead."
+#endif
+
+enum
+  {
+    FE_INVALID   =
+# define FE_INVALID	(0x01)
+      FE_INVALID,
+    FE_DIVBYZERO =
+# define FE_DIVBYZERO	(0x02)
+      FE_DIVBYZERO,
+    FE_OVERFLOW  =
+# define FE_OVERFLOW	(0x04)
+      FE_OVERFLOW,
+    FE_UNDERFLOW =
+# define FE_UNDERFLOW	(0x08)
+      FE_UNDERFLOW,
+    FE_INEXACT   =
+# define FE_INEXACT	(0x10)
+      FE_INEXACT
+  };
+
+# define FE_ALL_EXCEPT \
+	(FE_INVALID | FE_DIVBYZERO | FE_OVERFLOW | FE_UNDERFLOW | FE_INEXACT)
+
+enum
+  {
+    FE_TOWARDZERO =
+# define FE_TOWARDZERO	(0x0)
+      FE_TOWARDZERO,
+    FE_TONEAREST  =
+# define FE_TONEAREST	(0x1)	/* default */
+      FE_TONEAREST,
+    FE_UPWARD     =
+# define FE_UPWARD	(0x2)
+      FE_UPWARD,
+    FE_DOWNWARD   =
+# define FE_DOWNWARD	(0x3)
+      FE_DOWNWARD
+  };
+
+typedef unsigned int fexcept_t;
+
+typedef struct
+{
+  unsigned int __fpcr;
+  unsigned int __fpsr;
+} fenv_t;
+
+/* If the default argument is used we use this value.  */
+#define FE_DFL_ENV	((const fenv_t *) -1)
+
+#if __GLIBC_USE (IEC_60559_BFP_EXT)
+/* Type representing floating-point control modes.  */
+typedef unsigned int femode_t;
+
+/* Default floating-point control modes.  */
+# define FE_DFL_MODE	((const femode_t *) -1L)
+#endif
diff --git a/sysdeps/arc/bits/link.h b/sysdeps/arc/bits/link.h
new file mode 100644
index 000000000000..0acbc1349e08
--- /dev/null
+++ b/sysdeps/arc/bits/link.h
@@ -0,0 +1,52 @@
+/* Machine-specific declarations for dynamic linker interface, ARC version.
+   Copyright (C) 2009-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef	_LINK_H
+# error "Never include <bits/link.h> directly; use <link.h> instead."
+#endif
+
+/* Registers for entry into PLT on ARC.  */
+typedef struct La_arc_regs
+{
+  uint32_t lr_reg[8]; /* r0 through r7 (upto 8 args).  */
+} La_arc_regs;
+
+/* Return values for calls from PLT on ARC.  */
+typedef struct La_arc_retval
+{
+  /* For ARCv2, a 64-bit integer return value can use 2 regs.  */
+  uint32_t lrv_reg[2];
+} La_arc_retval;
+
+__BEGIN_DECLS
+
+extern ElfW(Addr) la_arc_gnu_pltenter (ElfW(Sym) *__sym, unsigned int __ndx,
+					 uintptr_t *__refcook,
+					 uintptr_t *__defcook,
+					 La_arc_regs *__regs,
+					 unsigned int *__flags,
+					 const char *__symname,
+					 long int *__framesizep);
+extern unsigned int la_arc_gnu_pltexit (ElfW(Sym) *__sym, unsigned int __ndx,
+					  uintptr_t *__refcook,
+					  uintptr_t *__defcook,
+					  const La_arc_regs *__inregs,
+					  La_arc_retval *__outregs,
+					  const char *symname);
+
+__END_DECLS
diff --git a/sysdeps/arc/bits/setjmp.h b/sysdeps/arc/bits/setjmp.h
new file mode 100644
index 000000000000..333e5cce3bea
--- /dev/null
+++ b/sysdeps/arc/bits/setjmp.h
@@ -0,0 +1,26 @@
+/* Define the machine-dependent type `jmp_buf'.  ARC version.
+   Copyright (C) 1992-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _ARC_BITS_SETJMP_H
+#define _ARC_BITS_SETJMP_H 1
+
+/* Saves r13-r25 (callee-saved), fp (frame pointer), sp (stack pointer),
+   blink (branch-n-link).  */
+typedef long int __jmp_buf[32];
+
+#endif
diff --git a/sysdeps/arc/bsd-_setjmp.S b/sysdeps/arc/bsd-_setjmp.S
new file mode 100644
index 000000000000..90b99cd8c3e0
--- /dev/null
+++ b/sysdeps/arc/bsd-_setjmp.S
@@ -0,0 +1 @@
+/* _setjmp is in setjmp.S.  */
diff --git a/sysdeps/arc/bsd-setjmp.S b/sysdeps/arc/bsd-setjmp.S
new file mode 100644
index 000000000000..d3b823c118bc
--- /dev/null
+++ b/sysdeps/arc/bsd-setjmp.S
@@ -0,0 +1 @@
+/* setjmp is in setjmp.S.  */
diff --git a/sysdeps/arc/configure b/sysdeps/arc/configure
new file mode 100644
index 000000000000..52e286da2ebb
--- /dev/null
+++ b/sysdeps/arc/configure
@@ -0,0 +1,14 @@
+# This file is generated from configure.ac by Autoconf.  DO NOT EDIT!
+ # Local configure fragment for sysdeps/arc.
+
+$as_echo "#define PI_STATIC_AND_HIDDEN 1" >>confdefs.h
+
+libc_cv_have_sdata_section=no
+
+# For ARC, historically ; was used for comments and not newline
+# Later # also got added to comment list, but ; couldn't be switched to
+# canonical newline as there's lots of code out there which will break
+libc_cv_asm_line_sep='`'
+cat >>confdefs.h <<_ACEOF
+#define ASM_LINE_SEP $libc_cv_asm_line_sep
+_ACEOF
diff --git a/sysdeps/arc/configure.ac b/sysdeps/arc/configure.ac
new file mode 100644
index 000000000000..1074d312f033
--- /dev/null
+++ b/sysdeps/arc/configure.ac
@@ -0,0 +1,11 @@
+GLIBC_PROVIDES dnl See aclocal.m4 in the top level source directory.
+# Local configure fragment for sysdeps/arc.
+
+AC_DEFINE(PI_STATIC_AND_HIDDEN)
+libc_cv_have_sdata_section=no
+
+# For ARC, historically ; was used for comments and not newline
+# Later # also got added to comment list, but ; couldn't be switched to
+# canonical newline as there's lots of code out there which will break
+libc_cv_asm_line_sep='`'
+AC_DEFINE_UNQUOTED(ASM_LINE_SEP, $libc_cv_asm_line_sep)
diff --git a/sysdeps/arc/dl-machine.h b/sysdeps/arc/dl-machine.h
new file mode 100644
index 000000000000..610401f8336d
--- /dev/null
+++ b/sysdeps/arc/dl-machine.h
@@ -0,0 +1,340 @@
+/* Machine-dependent ELF dynamic relocation inline functions.  ARC version.
+   Copyright (C) 1995-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef dl_machine_h
+#define dl_machine_h
+
+#define ELF_MACHINE_NAME "arc"
+
+#include <entry.h>
+
+#ifndef ENTRY_POINT
+# error ENTRY_POINT needs to be defined for ARC
+#endif
+
+#include <string.h>
+#include <link.h>
+#include <dl-tls.h>
+
+/* Dynamic Linking ABI for ARCv2 ISA.
+
+                        PLT
+          --------------------------------	<---- DT_PLTGOT
+          |  ld r11, [pcl, off-to-GOT[1] |  0
+          |                              |  4
+   plt0   |  ld r10, [pcl, off-to-GOT[2] |  8
+          |                              | 12
+          |  j [r10]                     | 16
+          --------------------------------
+          |    Base address of GOT       | 20
+          --------------------------------
+          |  ld r12, [pcl, off-to-GOT[3] | 24
+   plt1   |                              |
+          |  j.d    [r12]                | 32
+          |  mov    r12, pcl             | 36
+          --------------------------------
+          |                              | 40
+          ~                              ~
+          ~                              ~
+          |                              |
+          --------------------------------
+
+               .got
+          --------------
+          |    [0]     |
+          |    ...     |  Runtime address for data symbols
+          |    [n]     |
+          --------------
+
+            .got.plt
+          --------------
+          |    [0]     |  Build address of .dynamic
+          --------------
+          |    [1]     |  Module info - setup by ld.so
+          --------------
+          |    [2]     |  resolver entry point
+          --------------
+          |    [3]     |
+          |    ...     |  Runtime address for function symbols
+          |    [f]     |
+          --------------
+
+   For ARCompact, the PLT is 12 bytes due to short instructions
+
+          --------------------------------
+          |  ld r12, [pcl, off-to-GOT[3] | 24   (12 bytes each)
+   plt1   |                              |
+          |  j_s.d  [r12]                | 32
+          |  mov_s  r12, pcl             | 34
+          --------------------------------
+          |                              | 36  */
+
+/* Return nonzero iff ELF header is compatible with the running host.  */
+static inline int
+elf_machine_matches_host (const Elf32_Ehdr *ehdr)
+{
+  return (ehdr->e_machine == EM_ARCV2		 /* ARC HS.  */
+	  || ehdr->e_machine == EM_ARC_COMPACT); /* ARC 700.  */
+}
+
+/* Get build time address of .dynamic as setup in GOT[0]
+   This is called very early in _dl_start() so it has not been relocated to
+   runtime value.  */
+static inline ElfW(Addr)
+elf_machine_dynamic (void)
+{
+  extern const ElfW(Addr) _GLOBAL_OFFSET_TABLE_[] attribute_hidden;
+  return _GLOBAL_OFFSET_TABLE_[0];
+}
+
+
+/* Return the run-time load address of the shared object.  */
+static inline ElfW(Addr)
+elf_machine_load_address (void)
+{
+  ElfW(Addr) build_addr, run_addr;
+
+  /* For build address, below generates
+     ld  r0, [pcl, _GLOBAL_OFFSET_TABLE_@pcl].  */
+  build_addr = elf_machine_dynamic ();
+  __asm__ ("add %0, pcl, _DYNAMIC@pcl	\n" : "=r" (run_addr));
+
+  return run_addr - build_addr;
+}
+
+/* Set up the loaded object described by L so its unrelocated PLT
+   entries will jump to the on-demand fixup code in dl-runtime.c.  */
+
+static inline int
+__attribute__ ((always_inline))
+elf_machine_runtime_setup (struct link_map *l, int lazy, int profile)
+{
+  extern void _dl_runtime_resolve (Elf32_Word);
+
+  if (l->l_info[DT_JMPREL] && lazy)
+    {
+      /* On ARC DT_PLTGOT point to .plt whose 5th word (after the PLT header)
+         contains the address of .got.  */
+      ElfW(Addr) *plt_base = (ElfW(Addr) *) D_PTR (l, l_info[DT_PLTGOT]);
+      ElfW(Addr) *got = (ElfW(Addr) *) (plt_base[5] + l->l_addr);
+
+      got[1] = (ElfW(Addr)) l;	/* Identify this shared object.  */
+
+      /* This function will get called to fix up the GOT entry indicated by
+	 the offset on the stack, and then jump to the resolved address.  */
+      got[2] = (ElfW(Addr)) &_dl_runtime_resolve;
+    }
+
+  return lazy;
+}
+
+/* What this code does:
+    -ldso starts execution here when kernel returns from execve()
+    -calls into generic ldso entry point _dl_start( )
+    -optionally adjusts argc for executable if exec passed as cmd
+    -calls into app main with address of finaliser.  */
+
+#define RTLD_START asm ("\
+.text								\n\
+.globl __start							\n\
+.type __start, @function					\n\
+__start:							\n\
+	; (1). bootstrap ld.so					\n\
+	bl.d    _dl_start                                       \n\
+	mov_s   r0, sp          ; pass ptr to aux vector tbl    \n\
+	mov r13, r0		; safekeep app elf entry point	\n\
+								\n\
+	; (2). If ldso ran with executable as arg		\n\
+	;      skip the extra args calc by dl_start()		\n\
+	ld_s    r1, [sp]       ; orig argc			\n\
+	ld      r12, [pcl, _dl_skip_args@pcl]                   \n\
+	breq	r12, 0, 1f					\n\
+								\n\
+	add2    sp, sp, r12    ; discard argv entries from stack\n\
+	sub_s   r1, r1, r12    ; adjusted argc, on stack        \n\
+	st_s    r1, [sp]                                        \n\
+	add	r2, sp, 4					\n\
+	ld	r3, [pcl, _dl_argv@gotpc]    ; ST doesn't support this addressing mode	\n\
+	st	r2, [r3]					\n\
+1:								\n\
+	; (3). call preinit stuff				\n\
+	ld	r0, [pcl, _rtld_local@pcl]			\n\
+	add	r2, sp, 4	; argv				\n\
+	add2	r3, r2, r1					\n\
+	add	r3, r3, 4	; env				\n\
+	bl	_dl_init@plt					\n\
+								\n\
+	; (4) call app elf entry point				\n\
+	add     r0, pcl, _dl_fini@pcl				\n\
+	j	[r13]						\n\
+								\n\
+	.size  __start,.-__start                                \n\
+	.previous                                               \n\
+");
+
+/* ELF_RTYPE_CLASS_PLT iff TYPE describes relocation of a PLT entry, so
+   PLT entries should not be allowed to define the value.
+   ELF_RTYPE_CLASS_NOCOPY iff TYPE should not be allowed to resolve to one
+   of the main executable's symbols, as for a COPY reloc.  */
+#define elf_machine_type_class(type)				\
+  ((((type) == R_ARC_JUMP_SLOT					\
+     || (type) == R_ARC_TLS_DTPMOD				\
+     || (type) == R_ARC_TLS_DTPOFF				\
+     || (type) == R_ARC_TLS_TPOFF) * ELF_RTYPE_CLASS_PLT)	\
+   | (((type) == R_ARC_COPY) * ELF_RTYPE_CLASS_COPY))
+
+/* A reloc type used for ld.so cmdline arg lookups to reject PLT entries.  */
+#define ELF_MACHINE_JMP_SLOT  R_ARC_JUMP_SLOT
+
+/* ARC uses Elf32_Rela relocations.  */
+#define ELF_MACHINE_NO_REL 1
+#define ELF_MACHINE_NO_RELA 0
+
+/* Fixup a PLT entry to bounce directly to the function at VALUE.  */
+
+static inline ElfW(Addr)
+elf_machine_fixup_plt (struct link_map *map, lookup_t t,
+		       const ElfW(Sym) *refsym, const ElfW(Sym) *sym,
+		       const Elf32_Rela *reloc,
+		       ElfW(Addr) *reloc_addr, ElfW(Addr) value)
+{
+  return *reloc_addr = value;
+}
+
+/* Return the final value of a plt relocation.  */
+static inline ElfW(Addr)
+elf_machine_plt_value (struct link_map *map, const Elf32_Rela *reloc,
+                       ElfW(Addr) value)
+{
+  return value;
+}
+
+/* Names of the architecture-specific auditing callback functions.  */
+#define ARCH_LA_PLTENTER arc_gnu_pltenter
+#define ARCH_LA_PLTEXIT arc_gnu_pltexit
+
+#endif /* dl_machine_h */
+
+#ifdef RESOLVE_MAP
+
+auto inline void
+__attribute__ ((always_inline))
+elf_machine_rela (struct link_map *map, const ElfW(Rela) *reloc,
+                  const ElfW(Sym) *sym, const struct r_found_version *version,
+                  void *const reloc_addr_arg, int skip_ifunc)
+{
+  ElfW(Addr) *const reloc_addr = reloc_addr_arg;
+  const unsigned int r_type = ELF32_R_TYPE (reloc->r_info);
+
+  if (__glibc_unlikely (r_type == R_ARC_RELATIVE))
+    *reloc_addr += map->l_addr;
+  else if (__glibc_unlikely (r_type == R_ARC_NONE))
+    return;
+  else
+    {
+      const ElfW(Sym) *const refsym = sym;
+      struct link_map *sym_map = RESOLVE_MAP (&sym, version, r_type);
+      ElfW(Addr) value = SYMBOL_ADDRESS (sym_map, sym, true);
+
+      switch (r_type)
+	{
+        case R_ARC_COPY:
+	  if (__glibc_unlikely (sym == NULL))
+            /* This can happen in trace mode if an object could not be
+               found.  */
+            break;
+
+	  size_t size = sym->st_size;
+          if (__glibc_unlikely (size != refsym->st_size))
+            {
+	    const char *strtab = (const void *) D_PTR (map, l_info[DT_STRTAB]);
+	    if (sym->st_size > refsym->st_size)
+	      size = refsym->st_size;
+	    if (sym->st_size > refsym->st_size || GLRO(dl_verbose))
+	      _dl_error_printf ("\
+  %s: Symbol `%s' has different size in shared object, consider re-linking\n",
+				rtld_progname ?: "<program name unknown>",
+				strtab + refsym->st_name);
+            }
+
+          memcpy (reloc_addr_arg, (void *) value, size);
+          break;
+	case R_ARC_GLOB_DAT:
+	case R_ARC_JUMP_SLOT:
+            *reloc_addr = value;
+          break;
+        case R_ARC_TLS_DTPMOD:
+          if (sym_map != NULL)
+            /* Get the information from the link map returned by the
+               resolv function.  */
+            *reloc_addr = sym_map->l_tls_modid;
+          break;
+
+        case R_ARC_TLS_DTPOFF:
+          if (sym != NULL)
+            /* Offset set by the linker in the GOT entry would be overwritten
+               by dynamic loader instead of added to the symbol location.
+               Other target have the same approach on DTSOFF relocs.  */
+            *reloc_addr += sym->st_value;
+          break;
+
+        case R_ARC_TLS_TPOFF:
+          if (sym != NULL)
+            {
+              CHECK_STATIC_TLS (map, sym_map);
+              *reloc_addr = sym_map->l_tls_offset + sym->st_value + reloc->r_addend;
+            }
+          break;
+        case R_ARC_32:
+          *reloc_addr += value + reloc->r_addend;
+          break;
+
+        case R_ARC_PC32:
+          *reloc_addr += value + reloc->r_addend - (unsigned long int) reloc_addr;
+          break;
+
+	default:
+          _dl_reloc_bad_type (map, r_type, 0);
+          break;
+	}
+    }
+}
+
+auto inline void
+__attribute__ ((always_inline))
+elf_machine_rela_relative (ElfW(Addr) l_addr, const ElfW(Rela) *reloc,
+			   void *const reloc_addr_arg)
+{
+  ElfW(Addr) *const reloc_addr = reloc_addr_arg;
+  *reloc_addr += l_addr; // + reloc->r_addend;
+}
+
+auto inline void
+__attribute__ ((always_inline))
+elf_machine_lazy_rel (struct link_map *map,
+		      ElfW(Addr) l_addr, const ElfW(Rela) *reloc,
+		      int skip_ifunc)
+{
+  ElfW(Addr) *const reloc_addr = (void *) (l_addr + reloc->r_offset);
+  if (ELF32_R_TYPE (reloc->r_info) == R_ARC_JUMP_SLOT)
+    *reloc_addr += l_addr;
+  else
+    _dl_reloc_bad_type (map, ELF32_R_TYPE (reloc->r_info), 1);
+}
+
+#endif /* RESOLVE_MAP */
diff --git a/sysdeps/arc/dl-runtime.c b/sysdeps/arc/dl-runtime.c
new file mode 100644
index 000000000000..a495f277d36f
--- /dev/null
+++ b/sysdeps/arc/dl-runtime.c
@@ -0,0 +1,39 @@
+/* dl-runtime helpers for ARC.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public License as
+   published by the Free Software Foundation; either version 2.1 of the
+   License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+/* PLT jump into resolver passes PC of PLTn, while _dl_fixup expects the
+   address of corresponding .rela.plt entry.  */
+
+#ifdef __A7__
+# define ARC_PLT_SIZE	12
+#else
+# define ARC_PLT_SIZE	16
+#endif
+
+#define reloc_index						\
+({								\
+  unsigned long int plt0 = D_PTR (l, l_info[DT_PLTGOT]);	\
+  unsigned long int pltn = reloc_arg;				\
+  /* Exclude PL0 and PLT1.  */					\
+  unsigned long int idx = (pltn - plt0)/ARC_PLT_SIZE - 2;	\
+  idx;								\
+})
+
+#define reloc_offset reloc_index * sizeof (PLTREL)
+
+#include <elf/dl-runtime.c>
diff --git a/sysdeps/arc/dl-sysdep.h b/sysdeps/arc/dl-sysdep.h
new file mode 100644
index 000000000000..6382c05bf485
--- /dev/null
+++ b/sysdeps/arc/dl-sysdep.h
@@ -0,0 +1,25 @@
+/* System-specific settings for dynamic linker code.  ARC version.
+   Copyright (C) 2009-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include_next <dl-sysdep.h>
+
+/* _dl_argv cannot be attribute_relro, because _dl_start_user
+   might write into it after _dl_start returns.  */
+#define DL_ARGV_NOT_RELRO 1
+
+#define DL_EXTERN_PROTECTED_DATA
diff --git a/sysdeps/arc/dl-tls.h b/sysdeps/arc/dl-tls.h
new file mode 100644
index 000000000000..2269ac6c3daa
--- /dev/null
+++ b/sysdeps/arc/dl-tls.h
@@ -0,0 +1,30 @@
+/* Thread-local storage handling in the ELF dynamic linker.  ARC version.
+   Copyright (C) 2012-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+
+/* Type used for the representation of TLS information in the GOT.  */
+typedef struct
+{
+  unsigned long int ti_module;
+  unsigned long int ti_offset;
+} tls_index;
+
+extern void *__tls_get_addr (tls_index *ti);
+
+/* Value used for dtv entries for which the allocation is delayed.  */
+#define TLS_DTV_UNALLOCATED	((void *) -1l)
diff --git a/sysdeps/arc/dl-trampoline.S b/sysdeps/arc/dl-trampoline.S
new file mode 100644
index 000000000000..3dad904caaf9
--- /dev/null
+++ b/sysdeps/arc/dl-trampoline.S
@@ -0,0 +1,80 @@
+/* PLT trampolines.  ARC version.
+   Copyright (C) 2005-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sysdep.h>
+#include <libc-symbols.h>
+
+#include <sysdep.h>
+#include <sys/syscall.h>
+
+/* Save the registers which resolver could possibly clobber
+	r0-r9: args to the function - symbol being resolved
+	r10-r12 are already clobbered by PLTn, PLT0 thus neednot be saved.  */
+
+.macro	SAVE_CALLER_SAVED
+	push_s	r0
+	push_s	r1
+	push_s	r2
+	push_s	r3
+	st.a	r4, [sp, -4]
+	st.a	r5, [sp, -4]
+	st.a	r6, [sp, -4]
+	st.a	r7, [sp, -4]
+	st.a	r8, [sp, -4]
+	st.a	r9, [sp, -4]
+	cfi_adjust_cfa_offset (40)
+	push_s	blink
+	cfi_adjust_cfa_offset (4)
+	cfi_rel_offset (blink, 0)
+.endm
+
+.macro RESTORE_CALLER_SAVED_BUT_R0
+	ld.ab	blink,[sp, 4]
+	cfi_adjust_cfa_offset (-4)
+	cfi_restore (blink)
+	ld.ab	r9, [sp, 4]
+	ld.ab	r8, [sp, 4]
+	ld.ab	r7, [sp, 4]
+	ld.ab	r6, [sp, 4]
+	ld.ab	r5, [sp, 4]
+	ld.ab	r4, [sp, 4]
+	pop_s   r3
+	pop_s   r2
+	pop_s   r1
+	cfi_adjust_cfa_offset (-36)
+.endm
+
+/* Upon entry, PLTn, which led us here, sets up the following regs
+	r11 = Module info (tpnt pointer as expected by resolver)
+	r12 = PC of the PLTn itself - needed by resolver to find
+	      corresponding .rela.plt entry.  */
+
+ENTRY (_dl_runtime_resolve)
+	; args to func being resolved, which resolver might clobber
+	SAVE_CALLER_SAVED
+
+	mov_s 	r1, r12
+	bl.d  	_dl_fixup
+	mov   	r0, r11
+
+	RESTORE_CALLER_SAVED_BUT_R0
+	j_s.d   [r0]    /* r0 has resolved function addr.  */
+	pop_s   r0      /* restore first arg to resolved call.  */
+	cfi_adjust_cfa_offset (-4)
+	cfi_restore (r0)
+END (_dl_runtime_resolve)
diff --git a/sysdeps/arc/entry.h b/sysdeps/arc/entry.h
new file mode 100644
index 000000000000..adb01d981afd
--- /dev/null
+++ b/sysdeps/arc/entry.h
@@ -0,0 +1,5 @@
+#ifndef __ASSEMBLY__
+extern void __start (void) attribute_hidden;
+#endif
+
+#define ENTRY_POINT __start
diff --git a/sysdeps/arc/fpu/e_sqrt.c b/sysdeps/arc/fpu/e_sqrt.c
new file mode 100644
index 000000000000..8614606c632a
--- /dev/null
+++ b/sysdeps/arc/fpu/e_sqrt.c
@@ -0,0 +1,26 @@
+/* Square root of floating point number.
+   Copyright (C) 2015-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <math_private.h>
+
+double
+__ieee754_sqrt (double d)
+{
+  return __builtin_sqrt (d);
+}
+strong_alias (__ieee754_sqrt, __sqrt_finite)
diff --git a/sysdeps/arc/fpu/e_sqrtf.c b/sysdeps/arc/fpu/e_sqrtf.c
new file mode 100644
index 000000000000..6a5026df20dc
--- /dev/null
+++ b/sysdeps/arc/fpu/e_sqrtf.c
@@ -0,0 +1,26 @@
+/* Single-precision floating point square root.
+   Copyright (C) 2015-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <math_private.h>
+
+float
+__ieee754_sqrtf (float s)
+{
+  return __builtin_sqrtf (s);
+}
+strong_alias (__ieee754_sqrtf, __sqrtf_finite)
diff --git a/sysdeps/arc/fpu/fclrexcpt.c b/sysdeps/arc/fpu/fclrexcpt.c
new file mode 100644
index 000000000000..549968dcd465
--- /dev/null
+++ b/sysdeps/arc/fpu/fclrexcpt.c
@@ -0,0 +1,36 @@
+/* Clear given exceptions in current floating-point environment.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+int
+feclearexcept (int excepts)
+{
+  unsigned int fpsr;
+
+  _FPU_GETS (fpsr);
+
+  /* Clear the relevant bits, FWE is preserved.  */
+  fpsr &= ~excepts;
+
+  _FPU_SETS (fpsr);
+
+  return 0;
+}
+libm_hidden_def (feclearexcept)
diff --git a/sysdeps/arc/fpu/fegetenv.c b/sysdeps/arc/fpu/fegetenv.c
new file mode 100644
index 000000000000..058652aeb685
--- /dev/null
+++ b/sysdeps/arc/fpu/fegetenv.c
@@ -0,0 +1,37 @@
+/* Store current floating-point environment.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+int
+__fegetenv (fenv_t *envp)
+{
+  unsigned int fpcr;
+  unsigned int fpsr;
+
+  _FPU_GETCW (fpcr);
+  _FPU_GETS (fpsr);
+  envp->__fpcr = fpcr;
+  envp->__fpsr = fpsr;
+
+  return 0;
+}
+libm_hidden_def (__fegetenv)
+weak_alias (__fegetenv, fegetenv)
+libm_hidden_weak (fegetenv)
diff --git a/sysdeps/arc/fpu/fegetmode.c b/sysdeps/arc/fpu/fegetmode.c
new file mode 100644
index 000000000000..30d809552fbc
--- /dev/null
+++ b/sysdeps/arc/fpu/fegetmode.c
@@ -0,0 +1,31 @@
+/* Store current floating-point control modes.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+int
+fegetmode (femode_t *modep)
+{
+  unsigned int fpcr;
+
+  _FPU_GETCW (fpcr);
+  *modep = fpcr >> __FPU_RND_SHIFT;
+
+  return 0;
+}
diff --git a/sysdeps/arc/fpu/fegetround.c b/sysdeps/arc/fpu/fegetround.c
new file mode 100644
index 000000000000..ebb3b34e65f3
--- /dev/null
+++ b/sysdeps/arc/fpu/fegetround.c
@@ -0,0 +1,32 @@
+/* Return current rounding direction.
+   Copyright (C) 1998-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fenv_private.h>
+
+int
+__fegetround (void)
+{
+  unsigned int fpcr;
+  _FPU_GETCW (fpcr);
+
+  return fpcr >> __FPU_RND_SHIFT;
+}
+libm_hidden_def (__fegetround)
+weak_alias (__fegetround, fegetround)
+libm_hidden_weak (fegetround)
diff --git a/sysdeps/arc/fpu/feholdexcpt.c b/sysdeps/arc/fpu/feholdexcpt.c
new file mode 100644
index 000000000000..4b849a3cf05b
--- /dev/null
+++ b/sysdeps/arc/fpu/feholdexcpt.c
@@ -0,0 +1,43 @@
+/* Store current floating-point environment and clear exceptions.
+   Copyright (C) 2000-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fenv_private.h>
+
+int
+__feholdexcept (fenv_t *envp)
+{
+  unsigned int fpcr;
+  unsigned int fpsr;
+
+  _FPU_GETCW (fpcr);
+  _FPU_GETS (fpsr);
+
+  envp->__fpcr = fpcr;
+  envp->__fpsr = fpsr;
+
+  fpsr &= ~FE_ALL_EXCEPT;
+
+  _FPU_SETCW (fpcr);
+  _FPU_SETS (fpsr);
+
+  return 0;
+}
+libm_hidden_def (__feholdexcept)
+weak_alias (__feholdexcept, feholdexcept)
+libm_hidden_weak (feholdexcept)
diff --git a/sysdeps/arc/fpu/fesetenv.c b/sysdeps/arc/fpu/fesetenv.c
new file mode 100644
index 000000000000..828b51cf8afa
--- /dev/null
+++ b/sysdeps/arc/fpu/fesetenv.c
@@ -0,0 +1,48 @@
+/* Install given floating-point environment (doesnot raise exceptions).
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+int
+__fesetenv (const fenv_t *envp)
+{
+  unsigned int fpcr;
+  unsigned int fpsr;
+
+  if (envp == FE_DFL_ENV)
+    {
+      fpcr = _FPU_DEFAULT;
+      fpsr = _FPU_FPSR_DEFAULT;
+    }
+  else
+    {
+      /* No need to mask out reserved bits as they are IoW.  */
+      fpcr = envp->__fpcr;
+      fpsr = envp->__fpsr;
+    }
+
+  _FPU_SETCW (fpcr);
+  _FPU_SETS (fpsr);
+
+  /* Success.  */
+  return 0;
+}
+libm_hidden_def (__fesetenv)
+weak_alias (__fesetenv, fesetenv)
+libm_hidden_weak (fesetenv)
diff --git a/sysdeps/arc/fpu/fesetexcept.c b/sysdeps/arc/fpu/fesetexcept.c
new file mode 100644
index 000000000000..0a1bcf763bee
--- /dev/null
+++ b/sysdeps/arc/fpu/fesetexcept.c
@@ -0,0 +1,32 @@
+/* Set given exception flags.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+int
+fesetexcept (int excepts)
+{
+  unsigned int fpsr;
+
+  _FPU_GETS (fpsr);
+  fpsr |= excepts;
+  _FPU_SETS (fpsr);
+
+  return 0;
+}
diff --git a/sysdeps/arc/fpu/fesetmode.c b/sysdeps/arc/fpu/fesetmode.c
new file mode 100644
index 000000000000..473a8d176b6a
--- /dev/null
+++ b/sysdeps/arc/fpu/fesetmode.c
@@ -0,0 +1,41 @@
+/* Install given floating-point control modes.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+int
+fesetmode (const femode_t *modep)
+{
+  unsigned int fpcr;
+
+
+  if (modep == FE_DFL_MODE)
+    {
+      fpcr = _FPU_DEFAULT;
+    }
+  else
+    {
+      _FPU_GETCW (fpcr);
+      fpcr = (fpcr & ~(FE_DOWNWARD << __FPU_RND_SHIFT)) | (*modep << __FPU_RND_SHIFT);
+    }
+
+  _FPU_SETCW (fpcr);
+
+  return 0;
+}
diff --git a/sysdeps/arc/fpu/fesetround.c b/sysdeps/arc/fpu/fesetround.c
new file mode 100644
index 000000000000..3b4a34b4f6f4
--- /dev/null
+++ b/sysdeps/arc/fpu/fesetround.c
@@ -0,0 +1,39 @@
+/* Set current rounding direction.
+   Copyright (C) 1998-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fenv_private.h>
+
+int
+__fesetround (int round)
+{
+  unsigned int fpcr;
+
+  _FPU_GETCW (fpcr);
+
+  if (__glibc_unlikely (((fpcr >> __FPU_RND_SHIFT) & FE_DOWNWARD) != round))
+    {
+      fpcr = (fpcr & ~(FE_DOWNWARD << __FPU_RND_SHIFT)) | (round << __FPU_RND_SHIFT);
+      _FPU_SETCW (fpcr);
+    }
+
+  return 0;
+}
+libm_hidden_def (__fesetround)
+weak_alias (__fesetround, fesetround)
+libm_hidden_weak (fesetround)
diff --git a/sysdeps/arc/fpu/feupdateenv.c b/sysdeps/arc/fpu/feupdateenv.c
new file mode 100644
index 000000000000..09c0dff79d17
--- /dev/null
+++ b/sysdeps/arc/fpu/feupdateenv.c
@@ -0,0 +1,46 @@
+/* Install given floating-point environment and raise exceptions,
+   without clearing currently raised exceptions.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+int
+__feupdateenv (const fenv_t *envp)
+{
+  unsigned int fpcr;
+  unsigned int fpsr;
+
+  _FPU_GETCW (fpcr);
+  _FPU_GETS (fpsr);
+
+  /* rounding mode set to what is in env.  */
+  fpcr = envp->__fpcr;
+
+  /* currently raised exceptions are OR'ed with env.  */
+  fpsr |= envp->__fpsr;
+
+  _FPU_SETCW (fpcr);
+  _FPU_SETS (fpsr);
+
+  /* Success.  */
+  return 0;
+}
+libm_hidden_def (__feupdateenv)
+weak_alias (__feupdateenv, feupdateenv)
+libm_hidden_weak (feupdateenv)
diff --git a/sysdeps/arc/fpu/fgetexcptflg.c b/sysdeps/arc/fpu/fgetexcptflg.c
new file mode 100644
index 000000000000..9d1423eaeecb
--- /dev/null
+++ b/sysdeps/arc/fpu/fgetexcptflg.c
@@ -0,0 +1,31 @@
+/* Store current representation for exceptions, ARC version.
+   Copyright (C) 1998-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fenv_private.h>
+
+int
+fegetexceptflag (fexcept_t *flagp, int excepts)
+{
+  unsigned int fpsr;
+
+  _FPU_GETS (fpsr);
+  *flagp = fpsr & excepts;
+
+  return 0;
+}
diff --git a/sysdeps/arc/fpu/fraiseexcpt.c b/sysdeps/arc/fpu/fraiseexcpt.c
new file mode 100644
index 000000000000..9b9d6a951f42
--- /dev/null
+++ b/sysdeps/arc/fpu/fraiseexcpt.c
@@ -0,0 +1,39 @@
+/* Raise given exceptions.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+#include <float.h>
+#include <math.h>
+
+int
+__feraiseexcept (int excepts)
+{
+  unsigned int fpsr;
+
+  /* currently raised exceptions are not cleared.  */
+  _FPU_GETS (fpsr);
+  fpsr |= excepts;
+
+  _FPU_SETS (fpsr);
+
+  return 0;
+}
+libm_hidden_def (__feraiseexcept)
+weak_alias (__feraiseexcept, feraiseexcept)
+libm_hidden_weak (feraiseexcept)
diff --git a/sysdeps/arc/fpu/fsetexcptflg.c b/sysdeps/arc/fpu/fsetexcptflg.c
new file mode 100644
index 000000000000..b8e495692145
--- /dev/null
+++ b/sysdeps/arc/fpu/fsetexcptflg.c
@@ -0,0 +1,38 @@
+/* Set floating-point environment exception handling, ARC version.
+   Copyright (C) 1998-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+int
+fesetexceptflag (const fexcept_t *flagp, int excepts)
+{
+  unsigned int fpsr;
+
+  _FPU_GETS (fpsr);
+
+  /* Clear the bits first.  */
+  fpsr &= ~excepts;
+
+  /* Now set those bits, copying them over from @flagp.  */
+  fpsr |= *flagp & excepts;
+
+  _FPU_SETS (fpsr);
+
+  return 0;
+}
diff --git a/sysdeps/arc/fpu/ftestexcept.c b/sysdeps/arc/fpu/ftestexcept.c
new file mode 100644
index 000000000000..84fd3cf0469c
--- /dev/null
+++ b/sysdeps/arc/fpu/ftestexcept.c
@@ -0,0 +1,33 @@
+/* Test exception in current environment.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <fenv.h>
+#include <fpu_control.h>
+#include <fenv_private.h>
+#include <stdio.h>
+
+int
+fetestexcept (int excepts)
+{
+  unsigned int fpsr;
+
+  _FPU_GETS (fpsr);
+
+  return fpsr & excepts;
+}
+libm_hidden_def (fetestexcept)
diff --git a/sysdeps/arc/fpu/libm-test-ulps b/sysdeps/arc/fpu/libm-test-ulps
new file mode 100644
index 000000000000..4883d1c8f528
--- /dev/null
+++ b/sysdeps/arc/fpu/libm-test-ulps
@@ -0,0 +1,1703 @@
+# Begin of automatic generation
+
+# Maximal error of functions:
+Function: "acos":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "acos_downward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "acos_towardzero":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "acos_upward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "acosh":
+double: 3
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "acosh_downward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "acosh_towardzero":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "acosh_upward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "asin":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "asin_downward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "asin_towardzero":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "asin_upward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "asinh":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: "asinh_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "asinh_towardzero":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "asinh_upward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "atan":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "atan2":
+double: 7
+float: 2
+idouble: 7
+ifloat: 2
+
+Function: "atan2_downward":
+double: 5
+float: 2
+idouble: 5
+ifloat: 2
+
+Function: "atan2_towardzero":
+double: 5
+float: 2
+idouble: 5
+ifloat: 2
+
+Function: "atan2_upward":
+double: 8
+float: 2
+idouble: 8
+ifloat: 2
+
+Function: "atan_downward":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "atan_towardzero":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "atan_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "atanh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "atanh_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "atanh_towardzero":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "atanh_upward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "cabs":
+double: 1
+float: 1
+idouble: 1
+
+Function: "cabs_downward":
+double: 1
+idouble: 1
+
+Function: "cabs_towardzero":
+double: 1
+idouble: 1
+
+Function: "cabs_upward":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: Real part of "cacos":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Imaginary part of "cacos":
+double: 5
+float: 3
+idouble: 5
+ifloat: 4
+
+Function: Real part of "cacos_downward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "cacos_downward":
+double: 5
+float: 3
+idouble: 5
+ifloat: 3
+
+Function: Real part of "cacos_towardzero":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "cacos_towardzero":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Real part of "cacos_upward":
+double: 2
+float: 3
+idouble: 2
+ifloat: 3
+
+Function: Imaginary part of "cacos_upward":
+double: 5
+float: 5
+idouble: 5
+ifloat: 5
+
+Function: Real part of "cacosh":
+double: 5
+float: 4
+idouble: 5
+ifloat: 3
+
+Function: Imaginary part of "cacosh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "cacosh_downward":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "cacosh_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "cacosh_towardzero":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "cacosh_towardzero":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Real part of "cacosh_upward":
+double: 5
+float: 3
+idouble: 5
+ifloat: 3
+
+Function: Imaginary part of "cacosh_upward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "carg":
+double: 7
+float: 2
+idouble: 7
+ifloat: 2
+
+Function: "carg_downward":
+double: 5
+float: 2
+idouble: 5
+ifloat: 2
+
+Function: "carg_towardzero":
+double: 5
+float: 2
+idouble: 5
+ifloat: 2
+
+Function: "carg_upward":
+double: 8
+float: 2
+idouble: 8
+ifloat: 2
+
+Function: Real part of "casin":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: Imaginary part of "casin":
+double: 5
+float: 4
+idouble: 5
+ifloat: 3
+
+Function: Real part of "casin_downward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "casin_downward":
+double: 5
+float: 3
+idouble: 5
+ifloat: 3
+
+Function: Real part of "casin_towardzero":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: Imaginary part of "casin_towardzero":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Real part of "casin_upward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "casin_upward":
+double: 5
+float: 5
+idouble: 5
+ifloat: 5
+
+Function: Real part of "casinh":
+double: 5
+float: 4
+idouble: 5
+ifloat: 3
+
+Function: Imaginary part of "casinh":
+double: 3
+float: 2
+idouble: 3
+ifloat: 1
+
+Function: Real part of "casinh_downward":
+double: 5
+float: 3
+idouble: 5
+ifloat: 3
+
+Function: Imaginary part of "casinh_downward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Real part of "casinh_towardzero":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "casinh_towardzero":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: Real part of "casinh_upward":
+double: 5
+float: 5
+idouble: 5
+ifloat: 5
+
+Function: Imaginary part of "casinh_upward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Real part of "catan":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Imaginary part of "catan":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "catan_downward":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: Imaginary part of "catan_downward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "catan_towardzero":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: Imaginary part of "catan_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "catan_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Imaginary part of "catan_upward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "catanh":
+double: 4
+float: 4
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "catanh":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: Real part of "catanh_downward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Imaginary part of "catanh_downward":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: Real part of "catanh_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Imaginary part of "catanh_towardzero":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: Real part of "catanh_upward":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: Imaginary part of "catanh_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "cbrt":
+double: 4
+float: 1
+idouble: 4
+ifloat: 1
+
+Function: "cbrt_downward":
+double: 4
+float: 1
+idouble: 4
+ifloat: 1
+
+Function: "cbrt_towardzero":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: "cbrt_upward":
+double: 5
+float: 1
+idouble: 5
+ifloat: 1
+
+Function: Real part of "ccos":
+double: 3
+float: 3
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "ccos":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "ccos_downward":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: Imaginary part of "ccos_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "ccos_towardzero":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "ccos_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "ccos_upward":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "ccos_upward":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: Real part of "ccosh":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Imaginary part of "ccosh":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "ccosh_downward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "ccosh_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "ccosh_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Imaginary part of "ccosh_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "ccosh_upward":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: Imaginary part of "ccosh_upward":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: Real part of "cexp":
+double: 4
+float: 3
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "cexp":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: Real part of "cexp_downward":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "cexp_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "cexp_towardzero":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "cexp_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "cexp_upward":
+double: 5
+float: 3
+idouble: 5
+ifloat: 3
+
+Function: Imaginary part of "cexp_upward":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: Real part of "clog":
+double: 5
+float: 4
+idouble: 5
+ifloat: 4
+
+Function: Imaginary part of "clog":
+double: 7
+float: 2
+idouble: 7
+ifloat: 2
+
+Function: Real part of "clog10":
+double: 6
+float: 5
+idouble: 6
+ifloat: 5
+
+Function: Imaginary part of "clog10":
+double: 8
+float: 4
+idouble: 8
+ifloat: 4
+
+Function: Real part of "clog10_downward":
+double: 5
+float: 5
+idouble: 5
+ifloat: 5
+
+Function: Imaginary part of "clog10_downward":
+double: 8
+float: 4
+idouble: 8
+ifloat: 4
+
+Function: Real part of "clog10_towardzero":
+double: 6
+float: 6
+idouble: 6
+ifloat: 6
+
+Function: Imaginary part of "clog10_towardzero":
+double: 9
+float: 4
+idouble: 9
+ifloat: 4
+
+Function: Real part of "clog10_upward":
+double: 6
+float: 6
+idouble: 6
+ifloat: 6
+
+Function: Imaginary part of "clog10_upward":
+double: 9
+float: 5
+idouble: 9
+ifloat: 5
+
+Function: Real part of "clog_downward":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: Imaginary part of "clog_downward":
+double: 5
+float: 2
+idouble: 5
+ifloat: 2
+
+Function: Real part of "clog_towardzero":
+double: 5
+float: 4
+idouble: 5
+ifloat: 4
+
+Function: Imaginary part of "clog_towardzero":
+double: 5
+float: 3
+idouble: 5
+ifloat: 3
+
+Function: Real part of "clog_upward":
+double: 5
+float: 4
+idouble: 5
+ifloat: 4
+
+Function: Imaginary part of "clog_upward":
+double: 8
+float: 2
+idouble: 8
+ifloat: 2
+
+Function: "cos":
+double: 4
+float: 1
+idouble: 4
+ifloat: 1
+
+Function: "cos_downward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "cos_towardzero":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: "cos_upward":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: "cosh":
+double: 3
+float: 3
+idouble: 3
+ifloat: 2
+
+Function: "cosh_downward":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "cosh_towardzero":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "cosh_upward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Real part of "cpow":
+double: 9
+float: 8
+idouble: 9
+ifloat: 8
+
+Function: Imaginary part of "cpow":
+double: 3
+float: 6
+idouble: 3
+ifloat: 6
+
+Function: Real part of "cpow_downward":
+double: 5
+float: 8
+idouble: 5
+ifloat: 8
+
+Function: Imaginary part of "cpow_downward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "cpow_towardzero":
+double: 5
+float: 8
+idouble: 5
+ifloat: 8
+
+Function: Imaginary part of "cpow_towardzero":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "cpow_upward":
+double: 5
+float: 8
+idouble: 5
+ifloat: 8
+
+Function: Imaginary part of "cpow_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "csin":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Imaginary part of "csin":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "csin_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Imaginary part of "csin_downward":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: Real part of "csin_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Imaginary part of "csin_towardzero":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: Real part of "csin_upward":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: Imaginary part of "csin_upward":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Real part of "csinh":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Imaginary part of "csinh":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "csinh_downward":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: Imaginary part of "csinh_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "csinh_towardzero":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "csinh_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Real part of "csinh_upward":
+double: 4
+float: 2
+idouble: 4
+ifloat: 2
+
+Function: Imaginary part of "csinh_upward":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: Real part of "csqrt":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: Imaginary part of "csqrt":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: Real part of "csqrt_downward":
+double: 5
+float: 4
+idouble: 5
+ifloat: 4
+
+Function: Imaginary part of "csqrt_downward":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: Real part of "csqrt_towardzero":
+double: 5
+float: 4
+idouble: 5
+ifloat: 4
+
+Function: Imaginary part of "csqrt_towardzero":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: Real part of "csqrt_upward":
+double: 5
+float: 4
+idouble: 5
+ifloat: 4
+
+Function: Imaginary part of "csqrt_upward":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: Real part of "ctan":
+double: 4
+float: 6
+idouble: 4
+ifloat: 6
+
+Function: Imaginary part of "ctan":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Real part of "ctan_downward":
+double: 6
+float: 5
+idouble: 6
+ifloat: 5
+
+Function: Imaginary part of "ctan_downward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Real part of "ctan_towardzero":
+double: 5
+float: 6
+idouble: 5
+ifloat: 6
+
+Function: Imaginary part of "ctan_towardzero":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Real part of "ctan_upward":
+double: 5
+float: 6
+idouble: 5
+ifloat: 6
+
+Function: Imaginary part of "ctan_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "ctanh":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "ctanh":
+double: 4
+float: 6
+idouble: 4
+ifloat: 6
+
+Function: Real part of "ctanh_downward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "ctanh_downward":
+double: 6
+float: 5
+idouble: 6
+ifloat: 5
+
+Function: Real part of "ctanh_towardzero":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "ctanh_towardzero":
+double: 5
+float: 6
+idouble: 5
+ifloat: 6
+
+Function: Real part of "ctanh_upward":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: Imaginary part of "ctanh_upward":
+double: 5
+float: 6
+idouble: 5
+ifloat: 6
+
+Function: "erf":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "erf_downward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "erf_towardzero":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "erf_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "erfc":
+double: 5
+float: 5
+idouble: 5
+ifloat: 5
+
+Function: "erfc_downward":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: "erfc_towardzero":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: "erfc_upward":
+double: 5
+float: 5
+idouble: 5
+ifloat: 5
+
+Function: "exp":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "exp10":
+double: 4
+float: 1
+idouble: 4
+ifloat: 1
+
+Function: "exp10_downward":
+double: 3
+idouble: 3
+
+Function: "exp10_towardzero":
+double: 3
+idouble: 3
+
+Function: "exp10_upward":
+double: 4
+float: 1
+idouble: 4
+ifloat: 1
+
+Function: "exp2":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "exp2_downward":
+double: 1
+idouble: 1
+
+Function: "exp2_towardzero":
+double: 1
+idouble: 1
+
+Function: "exp2_upward":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "exp_downward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "exp_towardzero":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "exp_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "expm1":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "expm1_downward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "expm1_towardzero":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "expm1_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "gamma":
+double: 7
+float: 6
+idouble: 7
+ifloat: 6
+
+Function: "gamma_downward":
+double: 6
+float: 5
+idouble: 6
+ifloat: 5
+
+Function: "gamma_towardzero":
+double: 7
+float: 6
+idouble: 7
+ifloat: 6
+
+Function: "gamma_upward":
+double: 7
+float: 6
+idouble: 7
+ifloat: 6
+
+Function: "hypot":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "hypot_downward":
+double: 1
+idouble: 1
+
+Function: "hypot_towardzero":
+double: 1
+idouble: 1
+
+Function: "hypot_upward":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "j0":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: "j0_downward":
+double: 2
+float: 4
+idouble: 2
+ifloat: 4
+
+Function: "j0_towardzero":
+double: 3
+float: 5
+idouble: 3
+ifloat: 5
+
+Function: "j0_upward":
+double: 3
+float: 5
+idouble: 3
+ifloat: 5
+
+Function: "j1":
+double: 5
+float: 5
+idouble: 5
+ifloat: 5
+
+Function: "j1_downward":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: "j1_towardzero":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: "j1_upward":
+double: 5
+float: 5
+idouble: 5
+ifloat: 5
+
+Function: "jn":
+double: 9
+float: 8
+idouble: 9
+ifloat: 8
+
+Function: "jn_downward":
+double: 7
+float: 9
+idouble: 7
+ifloat: 9
+
+Function: "jn_towardzero":
+double: 7
+float: 9
+idouble: 7
+ifloat: 9
+
+Function: "jn_upward":
+double: 9
+float: 9
+idouble: 9
+ifloat: 9
+
+Function: "lgamma":
+double: 7
+float: 6
+idouble: 7
+ifloat: 6
+
+Function: "lgamma_downward":
+double: 6
+float: 5
+idouble: 6
+ifloat: 5
+
+Function: "lgamma_towardzero":
+double: 7
+float: 6
+idouble: 7
+ifloat: 6
+
+Function: "lgamma_upward":
+double: 7
+float: 6
+idouble: 7
+ifloat: 6
+
+Function: "log":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "log10":
+double: 2
+float: 3
+idouble: 2
+ifloat: 3
+
+Function: "log10_downward":
+double: 2
+float: 3
+idouble: 2
+ifloat: 3
+
+Function: "log10_towardzero":
+double: 2
+float: 4
+idouble: 2
+ifloat: 4
+
+Function: "log10_upward":
+double: 3
+float: 4
+idouble: 3
+ifloat: 4
+
+Function: "log1p":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "log1p_downward":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "log1p_towardzero":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "log1p_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "log2":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "log2_towardzero":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "log2_upward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "log_towardzero":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "log_upward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "pow":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "pow_downward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "pow_towardzero":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "pow_upward":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "sin":
+double: 7
+float: 1
+idouble: 7
+ifloat: 1
+
+Function: "sin_downward":
+double: 4
+float: 1
+idouble: 4
+ifloat: 1
+
+Function: "sin_towardzero":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: "sin_upward":
+double: 7
+float: 1
+idouble: 7
+ifloat: 1
+
+Function: "sincos":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "sincos_downward":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "sincos_towardzero":
+double: 4
+float: 1
+idouble: 4
+ifloat: 1
+
+Function: "sincos_upward":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "sinh":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "sinh_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "sinh_towardzero":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "sinh_upward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "tan":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "tan_downward":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "tan_towardzero":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "tan_upward":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "tanh":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: "tanh_downward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "tanh_towardzero":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "tanh_upward":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: "tgamma":
+double: 9
+float: 9
+idouble: 9
+ifloat: 9
+
+Function: "tgamma_downward":
+double: 9
+float: 9
+idouble: 9
+ifloat: 9
+
+Function: "tgamma_towardzero":
+double: 9
+float: 8
+idouble: 9
+ifloat: 8
+
+Function: "tgamma_upward":
+double: 9
+float: 9
+idouble: 9
+ifloat: 9
+
+Function: "y0":
+double: 3
+float: 6
+idouble: 3
+ifloat: 6
+
+Function: "y0_downward":
+double: 3
+float: 4
+idouble: 3
+ifloat: 4
+
+Function: "y0_towardzero":
+double: 3
+float: 4
+idouble: 3
+ifloat: 4
+
+Function: "y0_upward":
+double: 4
+float: 5
+idouble: 4
+ifloat: 5
+
+Function: "y1":
+double: 7
+float: 6
+idouble: 7
+ifloat: 6
+
+Function: "y1_downward":
+double: 6
+float: 6
+idouble: 6
+ifloat: 6
+
+Function: "y1_towardzero":
+double: 7
+float: 7
+idouble: 7
+ifloat: 7
+
+Function: "y1_upward":
+double: 7
+float: 7
+idouble: 7
+ifloat: 7
+
+Function: "yn":
+double: 9
+float: 9
+idouble: 9
+ifloat: 9
+
+Function: "yn_downward":
+double: 8
+float: 8
+idouble: 8
+ifloat: 8
+
+Function: "yn_towardzero":
+double: 9
+float: 9
+idouble: 9
+ifloat: 9
+
+Function: "yn_upward":
+double: 9
+float: 9
+idouble: 9
+ifloat: 9
+
+# end of automatic generation
diff --git a/sysdeps/arc/fpu/libm-test-ulps-name b/sysdeps/arc/fpu/libm-test-ulps-name
new file mode 100644
index 000000000000..8c4fba4f9ae0
--- /dev/null
+++ b/sysdeps/arc/fpu/libm-test-ulps-name
@@ -0,0 +1 @@
+ARC
diff --git a/sysdeps/arc/fpu/s_fma.c b/sysdeps/arc/fpu/s_fma.c
new file mode 100644
index 000000000000..48bb40482dc9
--- /dev/null
+++ b/sysdeps/arc/fpu/s_fma.c
@@ -0,0 +1,28 @@
+/* Copyright (C) 1996-2020 Free Software Foundation, Inc.
+
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <math.h>
+#include <libm-alias-double.h>
+
+double
+__fma (double x, double y, double z)
+{
+  return __builtin_fma (x, y, z);
+}
+
+libm_alias_double (__fma, fma)
diff --git a/sysdeps/arc/fpu/s_fmaf.c b/sysdeps/arc/fpu/s_fmaf.c
new file mode 100644
index 000000000000..544f32e27aec
--- /dev/null
+++ b/sysdeps/arc/fpu/s_fmaf.c
@@ -0,0 +1,28 @@
+/* Copyright (C) 2011-2020 Free Software Foundation, Inc.
+
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public License as
+   published by the Free Software Foundation; either version 2.1 of the
+   License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <math.h>
+#include <libm-alias-float.h>
+
+float
+__fmaf (float x, float y, float z)
+{
+  return __builtin_fmaf (x, y, z);
+}
+
+libm_alias_float (__fma, fma)
diff --git a/sysdeps/arc/fpu_control.h b/sysdeps/arc/fpu_control.h
new file mode 100644
index 000000000000..c318cc894871
--- /dev/null
+++ b/sysdeps/arc/fpu_control.h
@@ -0,0 +1,101 @@
+/* FPU control word bits.  ARC version.
+   Copyright (C) 2018-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _FPU_CONTROL_H
+#define _FPU_CONTROL_H
+
+/* ARC FPU control register bits.
+
+  [  0] -> IVE: Enable invalid operation exception.
+           if 0, soft exception: status register IV flag set.
+           if 1, hardware exception trap (not supported in Linux yet).
+  [  1] -> DZE: Enable division by zero exception.
+           if 0, soft exception: status register IV flag set.
+           if 1, hardware exception: (not supported in Linux yet).
+  [9:8] -> RM: Rounding Mode:
+           00 - Rounding toward zero.
+           01 - Rounding to nearest (default).
+           10 - Rounding (up) toward plus infinity.
+           11 - Rounding (down)toward minus infinity.
+
+   ARC FPU status register bits.
+
+   [ 0]  -> IV: flag invalid operation.
+   [ 1]  -> DZ: flag division by zero.
+   [ 2]  -> OV: flag Overflow operation.
+   [ 3]  -> UV: flag Underflow operation.
+   [ 4]  -> IX: flag Inexact operation.
+   [31]  -> FWE: Flag Write Enable.
+            If 1, above flags writable explicitly (clearing),
+            else IoW and only writable indirectly via bits [12:7].  */
+
+#include <features.h>
+
+#if !defined(__ARC_FPU_SP__) &&  !defined(__ARC_FPU_DP__)
+
+# define _FPU_RESERVED 0xffffffff
+# define _FPU_DEFAULT  0x00000000
+typedef unsigned int fpu_control_t;
+# define _FPU_GETCW(cw) (cw) = 0
+# define _FPU_SETCW(cw) (void) (cw)
+# define _FPU_GETS(cw) (cw) = 0
+# define _FPU_SETS(cw) (void) (cw)
+extern fpu_control_t __fpu_control;
+
+#else
+
+#define _FPU_RESERVED		0
+
+/* The fdlibm code requires strict IEEE double precision arithmetic,
+   and no interrupts for exceptions, rounding to nearest.
+   So only RM set to b'01.  */
+# define _FPU_DEFAULT		0x00000100
+
+/* Actually default needs to have FWE bit as 1 but that is already
+   ingrained into _FPU_SETS macro below.  */
+#define  _FPU_FPSR_DEFAULT	0x00000000
+
+#define __FPU_RND_SHIFT		8
+
+/* Type of the control word.  */
+typedef unsigned int fpu_control_t;
+
+/* Macros for accessing the hardware control word.  */
+#  define _FPU_GETCW(cw) __asm__ volatile ("lr %0, [0x300]" : "=r" (cw))
+#  define _FPU_SETCW(cw) __asm__ volatile ("sr %0, [0x300]" : : "r" (cw))
+
+/*  Macros for accessing the hardware status word.
+    FWE bit is special as it controls if actual status bits could be wrritten
+    explicitly (other than FPU instructions). We handle it here to keep the
+    callers agnostic of it:
+      - clear it out when reporting status bits
+      - always set it when changing status bits.  */
+#  define _FPU_GETS(cw) __asm__ volatile ("lr   %0, [0x301]	\r\n" \
+                                          "bclr %0, %0, 31	\r\n" \
+                                          : "=r" (cw))
+
+#  define _FPU_SETS(cw) __asm__ volatile ("bset %0, %0, 31	\r\n" \
+					  "sr   %0, [0x301]	\r\n" \
+                                          : : "r" (cw))
+
+/* Default control word set at startup.  */
+extern fpu_control_t __fpu_control;
+
+#endif
+
+#endif /* fpu_control.h */
diff --git a/sysdeps/arc/gccframe.h b/sysdeps/arc/gccframe.h
new file mode 100644
index 000000000000..5d547fd40a6c
--- /dev/null
+++ b/sysdeps/arc/gccframe.h
@@ -0,0 +1,21 @@
+/* Definition of object in frame unwind info.  ARC version.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#define FIRST_PSEUDO_REGISTER 40
+
+#include <sysdeps/generic/gccframe.h>
diff --git a/sysdeps/arc/get-rounding-mode.h b/sysdeps/arc/get-rounding-mode.h
new file mode 100644
index 000000000000..146290e3e0b9
--- /dev/null
+++ b/sysdeps/arc/get-rounding-mode.h
@@ -0,0 +1,38 @@
+/* Determine floating-point rounding mode within libc.  ARC version.
+   Copyright (C) 1998-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _ARC_GET_ROUNDING_MODE_H
+#define _ARC_GET_ROUNDING_MODE_H	1
+
+#include <fenv.h>
+#include <fpu_control.h>
+
+static inline int
+get_rounding_mode (void)
+{
+#if defined(__ARC_FPU_SP__) ||  defined(__ARC_FPU_DP__)
+  unsigned int fpcr;
+  _FPU_GETCW (fpcr);
+
+  return fpcr >> __FPU_RND_SHIFT;
+#else
+  return FE_TONEAREST;
+#endif
+}
+
+#endif /* get-rounding-mode.h */
diff --git a/sysdeps/arc/gmp-mparam.h b/sysdeps/arc/gmp-mparam.h
new file mode 100644
index 000000000000..5580551483c8
--- /dev/null
+++ b/sysdeps/arc/gmp-mparam.h
@@ -0,0 +1,23 @@
+/* gmp-mparam.h -- Compiler/machine parameter header file.
+
+Copyright (C) 2017-2020 Free Software Foundation, Inc.
+
+This file is part of the GNU MP Library.
+
+The GNU MP Library is free software; you can redistribute it and/or modify
+it under the terms of the GNU Lesser General Public License as published by
+the Free Software Foundation; either version 2.1 of the License, or (at your
+option) any later version.
+
+The GNU MP Library is distributed in the hope that it will be useful, but
+WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
+or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
+License for more details.
+
+You should have received a copy of the GNU Lesser General Public License
+along with the GNU MP Library; see the file COPYING.LIB.  If not, see
+<https://www.gnu.org/licenses/>.  */
+
+#include <sysdeps/generic/gmp-mparam.h>
+
+#define IEEE_DOUBLE_BIG_ENDIAN 0
diff --git a/sysdeps/arc/jmpbuf-offsets.h b/sysdeps/arc/jmpbuf-offsets.h
new file mode 100644
index 000000000000..31556a423347
--- /dev/null
+++ b/sysdeps/arc/jmpbuf-offsets.h
@@ -0,0 +1,47 @@
+/* Private macros for accessing __jmp_buf contents.  ARC version.
+   Copyright (C) 2006-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+/* Save offsets within __jmp_buf
+   We don't use most of these symbols; they are here for documentation. */
+
+/* Callee Regs.  */
+#define JB_R13 0
+#define JB_R14 1
+#define JB_R15 2
+#define JB_R16 3
+#define JB_R17 4
+#define JB_R18 5
+#define JB_R19 6
+#define JB_R20 7
+#define JB_R21 8
+#define JB_R22 9
+#define JB_R23 10
+#define JB_R24 11
+#define JB_R25 12
+
+/* Frame Pointer, Stack Pointer, Branch-n-link.  */
+#define JB_FP  13
+#define JB_SP  14
+#define JB_BLINK  15
+
+/* We save space for some extra state to accommodate future changes
+   This is number of words.  */
+#define JB_NUM	32
+
+/* Helper for generic ____longjmp_chk().  */
+#define JB_FRAME_ADDRESS(buf) ((void *) (unsigned long int) (buf[JB_SP]))
diff --git a/sysdeps/arc/jmpbuf-unwind.h b/sysdeps/arc/jmpbuf-unwind.h
new file mode 100644
index 000000000000..b333cd51c80e
--- /dev/null
+++ b/sysdeps/arc/jmpbuf-unwind.h
@@ -0,0 +1,47 @@
+/* Examine __jmp_buf for unwinding frames.  ARC version.
+   Copyright (C) 2005-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <setjmp.h>
+#include <jmpbuf-offsets.h>
+#include <stdint.h>
+#include <unwind.h>
+
+/* Test if longjmp to JMPBUF would unwind the frame
+   containing a local variable at ADDRESS.  */
+
+#define _JMPBUF_UNWINDS(jmpbuf, address, demangle) \
+  ((void *) (address) < (void *) demangle (jmpbuf[JB_SP]))
+
+#define _JMPBUF_CFA_UNWINDS_ADJ(_jmpbuf, _context, _adj) \
+  _JMPBUF_UNWINDS_ADJ (_jmpbuf, (void *) _Unwind_GetCFA (_context), _adj)
+
+static inline uintptr_t __attribute__ ((unused))
+_jmpbuf_sp (__jmp_buf jmpbuf)
+{
+  uintptr_t sp = jmpbuf[JB_SP];
+#ifdef PTR_DEMANGLE
+  PTR_DEMANGLE (sp);
+#endif
+  return sp;
+}
+
+#define _JMPBUF_UNWINDS_ADJ(_jmpbuf, _address, _adj) \
+  ((uintptr_t) (_address) - (_adj) < (uintptr_t) (_jmpbuf_sp (_jmpbuf) - (_adj)))
+
+/* We use the normal longjmp for unwinding.  */
+#define __libc_unwind_longjmp(buf, val) __libc_longjmp (buf, val)
diff --git a/sysdeps/arc/ldsodefs.h b/sysdeps/arc/ldsodefs.h
new file mode 100644
index 000000000000..c217a9d84b80
--- /dev/null
+++ b/sysdeps/arc/ldsodefs.h
@@ -0,0 +1,43 @@
+/* Run-time dynamic linker data structures for loaded ELF shared objects.
+   Copyright (C) 2000-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _ARC_LDSODEFS_H
+#define _ARC_LDSODEFS_H 1
+
+#include <elf.h>
+
+struct La_arc_regs;
+struct La_arc_retval;
+
+#define ARCH_PLTENTER_MEMBERS						\
+    ElfW(Addr) (*arc_gnu_pltenter) (ElfW(Sym) *, unsigned int,	\
+				      uintptr_t *, uintptr_t *,		\
+				      const struct La_arc_regs *,	\
+				      unsigned int *, const char *,	\
+				      long int *);
+
+#define ARCH_PLTEXIT_MEMBERS						\
+    unsigned int (*arc_gnu_pltexit) (ElfW(Sym) *, unsigned int,	\
+				       uintptr_t *, uintptr_t *,	\
+				       const struct La_arc_regs *,	\
+				       struct La_arc_retval *,	\
+				       const char *);
+
+#include_next <ldsodefs.h>
+
+#endif
diff --git a/sysdeps/arc/libc-tls.c b/sysdeps/arc/libc-tls.c
new file mode 100644
index 000000000000..ec88282de60e
--- /dev/null
+++ b/sysdeps/arc/libc-tls.c
@@ -0,0 +1,27 @@
+/* Thread-local storage handling in the ELF dynamic linker.  ARC version.
+   Copyright (C) 2005-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <csu/libc-tls.c>
+#include <dl-tls.h>
+
+void *
+__tls_get_addr (tls_index *ti)
+{
+  dtv_t *dtv = THREAD_DTV ();
+  return (char *) dtv[1].pointer.val + ti->ti_offset;
+}
diff --git a/sysdeps/arc/machine-gmon.h b/sysdeps/arc/machine-gmon.h
new file mode 100644
index 000000000000..5efbb55b9df5
--- /dev/null
+++ b/sysdeps/arc/machine-gmon.h
@@ -0,0 +1,35 @@
+/* Machine-dependent definitions for profiling support.  ARC version.
+   Copyright (C) 1996-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sysdep.h>
+
+#define _MCOUNT_DECL(frompc, selfpc)					\
+static void								\
+__mcount_internal (unsigned long int frompc, unsigned long int selfpc)
+
+/* This is very simple as gcc does all the heavy lifting at _mcount call site
+    - sets up caller's blink in r0, so frompc is setup correctly
+    - preserve argument registers for original call.  */
+
+#define MCOUNT								\
+void									\
+_mcount (void *frompc)							\
+{									\
+  __mcount_internal ((unsigned long int) frompc,			\
+		     (unsigned long int) __builtin_return_address(0));	\
+}
diff --git a/sysdeps/arc/math-tests-trap.h b/sysdeps/arc/math-tests-trap.h
new file mode 100644
index 000000000000..1a3581396573
--- /dev/null
+++ b/sysdeps/arc/math-tests-trap.h
@@ -0,0 +1,27 @@
+/* Configuration for math tests: support for enabling exception traps.
+   ARC version.
+   Copyright (C) 2014-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef ARC_MATH_TESTS_TRAP_H
+#define ARC_MATH_TESTS_TRAP_H 1
+
+/* Trapping exceptions are optional on ARC
+   and not supported in Linux kernel just yet.  */
+#define EXCEPTION_ENABLE_SUPPORTED(EXCEPT)	((EXCEPT) == 0)
+
+#endif /* math-tests-trap.h.  */
diff --git a/sysdeps/arc/memusage.h b/sysdeps/arc/memusage.h
new file mode 100644
index 000000000000..c72beb1ce9a4
--- /dev/null
+++ b/sysdeps/arc/memusage.h
@@ -0,0 +1,23 @@
+/* Machine-specific definitions for memory usage profiling, ARC version.
+   Copyright (C) 2000-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#define GETSP() ({ register uintptr_t stack_ptr asm ("sp"); stack_ptr; })
+
+#define uatomic32_t unsigned int
+
+#include <sysdeps/generic/memusage.h>
diff --git a/sysdeps/arc/nofpu/Implies b/sysdeps/arc/nofpu/Implies
new file mode 100644
index 000000000000..abcbadb25f22
--- /dev/null
+++ b/sysdeps/arc/nofpu/Implies
@@ -0,0 +1 @@
+ieee754/soft-fp
diff --git a/sysdeps/arc/nofpu/libm-test-ulps b/sysdeps/arc/nofpu/libm-test-ulps
new file mode 100644
index 000000000000..0e8ef313fa94
--- /dev/null
+++ b/sysdeps/arc/nofpu/libm-test-ulps
@@ -0,0 +1,390 @@
+# Begin of automatic generation
+
+# Maximal error of functions:
+Function: "acos":
+float: 1
+ifloat: 1
+
+Function: "acosh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "asin":
+float: 1
+ifloat: 1
+
+Function: "asinh":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "atan":
+float: 1
+ifloat: 1
+
+Function: "atan2":
+float: 1
+ifloat: 1
+
+Function: "atanh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "cabs":
+double: 1
+idouble: 1
+
+Function: Real part of "cacos":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: Imaginary part of "cacos":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "cacosh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Imaginary part of "cacosh":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "carg":
+float: 1
+ifloat: 1
+
+Function: Real part of "casin":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Imaginary part of "casin":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "casinh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Imaginary part of "casinh":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Real part of "catan":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Imaginary part of "catan":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Real part of "catanh":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Imaginary part of "catanh":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "cbrt":
+double: 3
+float: 1
+idouble: 3
+ifloat: 1
+
+Function: Real part of "ccos":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Imaginary part of "ccos":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Real part of "ccosh":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Imaginary part of "ccosh":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Real part of "cexp":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: Imaginary part of "cexp":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: Real part of "clog":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+Function: Imaginary part of "clog":
+float: 1
+ifloat: 1
+
+Function: Real part of "clog10":
+double: 3
+float: 4
+idouble: 3
+ifloat: 4
+
+Function: Imaginary part of "clog10":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "cos":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "cosh":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Real part of "cpow":
+double: 2
+float: 5
+idouble: 2
+ifloat: 5
+
+Function: Imaginary part of "cpow":
+float: 2
+ifloat: 2
+
+Function: Real part of "csin":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Real part of "csinh":
+float: 1
+ifloat: 1
+
+Function: Imaginary part of "csinh":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Real part of "csqrt":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Imaginary part of "csqrt":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "ctan":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: Imaginary part of "ctan":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Real part of "ctanh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: Imaginary part of "ctanh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "erf":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "erfc":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: "exp10":
+double: 2
+idouble: 2
+
+Function: "exp2":
+double: 1
+idouble: 1
+
+Function: "expm1":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "gamma":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: "hypot":
+double: 1
+idouble: 1
+
+Function: "j0":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "j1":
+double: 1
+float: 2
+idouble: 1
+ifloat: 2
+
+Function: "jn":
+double: 4
+float: 4
+idouble: 4
+ifloat: 4
+
+Function: "lgamma":
+double: 4
+float: 3
+idouble: 4
+ifloat: 3
+
+Function: "log10":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "log1p":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "log2":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "pow":
+double: 1
+idouble: 1
+
+Function: "sin":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "sincos":
+double: 1
+float: 1
+idouble: 1
+ifloat: 1
+
+Function: "sinh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "tan":
+float: 1
+ifloat: 1
+
+Function: "tanh":
+double: 2
+float: 2
+idouble: 2
+ifloat: 2
+
+Function: "tgamma":
+double: 5
+float: 4
+idouble: 5
+ifloat: 4
+
+Function: "y0":
+double: 2
+float: 1
+idouble: 2
+ifloat: 1
+
+Function: "y1":
+double: 3
+float: 2
+idouble: 3
+ifloat: 2
+
+Function: "yn":
+double: 3
+float: 3
+idouble: 3
+ifloat: 3
+
+# end of automatic generation
diff --git a/sysdeps/arc/nofpu/libm-test-ulps-name b/sysdeps/arc/nofpu/libm-test-ulps-name
new file mode 100644
index 000000000000..8a9879ebd635
--- /dev/null
+++ b/sysdeps/arc/nofpu/libm-test-ulps-name
@@ -0,0 +1 @@
+ARC soft-float
diff --git a/sysdeps/arc/nofpu/math-tests-exceptions.h b/sysdeps/arc/nofpu/math-tests-exceptions.h
new file mode 100644
index 000000000000..7d74720db94b
--- /dev/null
+++ b/sysdeps/arc/nofpu/math-tests-exceptions.h
@@ -0,0 +1,27 @@
+/* Configuration for math tests. exceptions support ARC version.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef ARC_NOFPU_MATH_TESTS_EXCEPTIONS_H
+#define ARC_NOFPU_MATH_TESTS_EXCEPTIONS_H 1
+
+/* Soft-float doesnot support exceptions.  */
+#define EXCEPTION_TESTS_float		0
+#define EXCEPTION_TESTS_double		0
+#define EXCEPTION_TESTS_long_double	0
+
+#endif
diff --git a/sysdeps/arc/nofpu/math-tests-rounding.h b/sysdeps/arc/nofpu/math-tests-rounding.h
new file mode 100644
index 000000000000..6e5376cb35b5
--- /dev/null
+++ b/sysdeps/arc/nofpu/math-tests-rounding.h
@@ -0,0 +1,27 @@
+/* Configuration for math tests: rounding mode support.  ARC version.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef ARC_NOFPU_MATH_TESTS_ROUNDING_H
+#define ARC_NOFPU_MATH_TESTS_ROUNDING_H 1
+
+/* Soft-float only supports to-nearest rounding mode.  */
+#define ROUNDING_TESTS_float(MODE)		((MODE) == FE_TONEAREST)
+#define ROUNDING_TESTS_double(MODE)		((MODE) == FE_TONEAREST)
+#define ROUNDING_TESTS_long_double(MODE)	((MODE) == FE_TONEAREST)
+
+#endif
diff --git a/sysdeps/arc/nptl/Makefile b/sysdeps/arc/nptl/Makefile
new file mode 100644
index 000000000000..6f387c53905d
--- /dev/null
+++ b/sysdeps/arc/nptl/Makefile
@@ -0,0 +1,22 @@
+# NPTL makefile fragment for ARC.
+# Copyright (C) 2005-2020 Free Software Foundation, Inc.
+#
+# This file is part of the GNU C Library.
+#
+# The GNU C Library is free software; you can redistribute it and/or
+# modify it under the terms of the GNU Lesser General Public
+# License as published by the Free Software Foundation; either
+# version 2.1 of the License, or (at your option) any later version.
+#
+# The GNU C Library is distributed in the hope that it will be useful,
+# but WITHOUT ANY WARRANTY; without even the implied warranty of
+# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+# Lesser General Public License for more details.
+#
+# You should have received a copy of the GNU Lesser General Public
+# License along with the GNU C Library.  If not, see
+# <https://www.gnu.org/licenses/>.
+
+ifeq ($(subdir),csu)
+gen-as-const-headers += tcb-offsets.sym
+endif
diff --git a/sysdeps/arc/nptl/bits/semaphore.h b/sysdeps/arc/nptl/bits/semaphore.h
new file mode 100644
index 000000000000..772dc4cb9b01
--- /dev/null
+++ b/sysdeps/arc/nptl/bits/semaphore.h
@@ -0,0 +1,32 @@
+/* Machine-specific POSIX semaphore type layouts.  ARC version.
+   Copyright (C) 2002-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _SEMAPHORE_H
+# error "Never use <bits/semaphore.h> directly; include <semaphore.h> instead."
+#endif
+
+#define __SIZEOF_SEM_T	16
+
+/* Value returned if `sem_open' failed.  */
+#define SEM_FAILED      ((sem_t *) 0)
+
+typedef union
+{
+  char __size[__SIZEOF_SEM_T];
+  long int __align;
+} sem_t;
diff --git a/sysdeps/arc/nptl/pthreaddef.h b/sysdeps/arc/nptl/pthreaddef.h
new file mode 100644
index 000000000000..b265bf1a052c
--- /dev/null
+++ b/sysdeps/arc/nptl/pthreaddef.h
@@ -0,0 +1,32 @@
+/* pthread machine parameter definitions, ARC version.
+   Copyright (C) 2002-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+/* Default stack size.  */
+#define ARCH_STACK_DEFAULT_SIZE	(2 * 1024 * 1024)
+
+/* Required stack pointer alignment at beginning.  */
+#define STACK_ALIGN		4
+
+/* Minimal stack size after allocating thread descriptor and guard size.  */
+#define MINIMAL_REST_STACK	2048
+
+/* Alignment requirement for TCB.  */
+#define TCB_ALIGNMENT		4
+
+/* Location of current stack frame.  */
+#define CURRENT_STACK_FRAME	__builtin_frame_address (0)
diff --git a/sysdeps/arc/nptl/tcb-offsets.sym b/sysdeps/arc/nptl/tcb-offsets.sym
new file mode 100644
index 000000000000..56950e0676ed
--- /dev/null
+++ b/sysdeps/arc/nptl/tcb-offsets.sym
@@ -0,0 +1,11 @@
+#include <sysdep.h>
+#include <tls.h>
+
+-- Derive offsets relative to the thread register.
+#define thread_offsetof(mem)	(long)(offsetof(struct pthread, mem) - sizeof(struct pthread))
+
+MULTIPLE_THREADS_OFFSET		offsetof (struct pthread, header.multiple_threads)
+TLS_PRE_TCB_SIZE		sizeof (struct pthread)
+TLS_TCB_SIZE            	sizeof(tcbhead_t)
+
+PTHREAD_TID			offsetof(struct pthread, tid)
diff --git a/sysdeps/arc/nptl/tls.h b/sysdeps/arc/nptl/tls.h
new file mode 100644
index 000000000000..d6b166c1f92b
--- /dev/null
+++ b/sysdeps/arc/nptl/tls.h
@@ -0,0 +1,150 @@
+/* Definition for thread-local data handling.  NPTL/ARC version.
+   Copyright (C) 2012-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _ARC_NPTL_TLS_H
+#define _ARC_NPTL_TLS_H	1
+
+#include <dl-sysdep.h>
+
+#ifndef __ASSEMBLER__
+# include <stdbool.h>
+# include <stddef.h>
+# include <stdint.h>
+
+#include <dl-dtv.h>
+
+/* Get system call information.  */
+# include <sysdep.h>
+
+/* The TLS blocks start right after the TCB.  */
+# define TLS_DTV_AT_TP	1
+# define TLS_TCB_AT_TP	0
+
+/* Get the thread descriptor definition.  */
+# include <nptl/descr.h>
+
+typedef struct
+{
+  dtv_t *dtv;
+  uintptr_t pointer_guard;
+} tcbhead_t;
+
+register struct pthread *__thread_self __asm__("r25");
+
+/* This is the size of the initial TCB.  */
+# define TLS_INIT_TCB_SIZE	sizeof (tcbhead_t)
+
+/* Alignment requirements for the initial TCB.  */
+# define TLS_INIT_TCB_ALIGN	__alignof__ (struct pthread)
+
+/* This is the size of the TCB.  */
+#ifndef TLS_TCB_SIZE
+# define TLS_TCB_SIZE		sizeof (tcbhead_t)
+#endif
+
+/* Alignment requirements for the TCB.  */
+# define TLS_TCB_ALIGN		__alignof__ (struct pthread)
+
+/* This is the size we need before TCB.  */
+# define TLS_PRE_TCB_SIZE	sizeof (struct pthread)
+
+/* Install the dtv pointer.  The pointer passed is to the element with
+   index -1 which contain the length.  */
+# define INSTALL_DTV(tcbp, dtvp) \
+  (((tcbhead_t *) (tcbp))->dtv = (dtvp) + 1)
+
+/* Install new dtv for current thread.  */
+# define INSTALL_NEW_DTV(dtv) \
+  (THREAD_DTV() = (dtv))
+
+/* Return dtv of given thread descriptor.  */
+# define GET_DTV(tcbp) \
+  (((tcbhead_t *) (tcbp))->dtv)
+
+/* Code to initially initialize the thread pointer.  */
+# define TLS_INIT_TP(tcbp)			\
+  ({                                            \
+	long result_var;			\
+	__builtin_set_thread_pointer(tcbp);     \
+	result_var = INTERNAL_SYSCALL (arc_settls, err, 1, (tcbp));	\
+	INTERNAL_SYSCALL_ERROR_P (result_var, err)			\
+	? "unknown error" : NULL;		\
+   })
+
+/* Value passed to 'clone' for initialization of the thread register.  */
+# define TLS_DEFINE_INIT_TP(tp, pd) void *tp = (pd) + 1
+
+/* Return the address of the dtv for the current thread.  */
+# define THREAD_DTV() \
+  (((tcbhead_t *) __builtin_thread_pointer ())->dtv)
+
+/* Return the thread descriptor for the current thread.  */
+# define THREAD_SELF \
+ ((struct pthread *)__builtin_thread_pointer () - 1)
+
+/* Magic for libthread_db to know how to do THREAD_SELF.  */
+# define DB_THREAD_SELF \
+  CONST_THREAD_AREA (32, sizeof (struct pthread))
+
+/* Access to data in the thread descriptor is easy.  */
+# define THREAD_GETMEM(descr, member) \
+  descr->member
+# define THREAD_GETMEM_NC(descr, member, idx) \
+  descr->member[idx]
+# define THREAD_SETMEM(descr, member, value) \
+  descr->member = (value)
+# define THREAD_SETMEM_NC(descr, member, idx, value) \
+  descr->member[idx] = (value)
+
+/* Get and set the global scope generation counter in struct pthread.  */
+#define THREAD_GSCOPE_IN_TCB      1
+#define THREAD_GSCOPE_FLAG_UNUSED 0
+#define THREAD_GSCOPE_FLAG_USED   1
+#define THREAD_GSCOPE_FLAG_WAIT   2
+#define THREAD_GSCOPE_RESET_FLAG() \
+  do									     \
+    { int __res								     \
+	= atomic_exchange_rel (&THREAD_SELF->header.gscope_flag,	     \
+			       THREAD_GSCOPE_FLAG_UNUSED);		     \
+      if (__res == THREAD_GSCOPE_FLAG_WAIT)				     \
+	lll_futex_wake (&THREAD_SELF->header.gscope_flag, 1, LLL_PRIVATE);   \
+    }									     \
+  while (0)
+#define THREAD_GSCOPE_SET_FLAG() \
+  do									     \
+    {									     \
+      THREAD_SELF->header.gscope_flag = THREAD_GSCOPE_FLAG_USED;	     \
+      atomic_write_barrier ();						     \
+    }									     \
+  while (0)
+#define THREAD_GSCOPE_WAIT() \
+  GL(dl_wait_lookup_done) ()
+
+#else
+
+# include <tcb-offsets.h>
+
+# r25 is dedicated TLS register for ARC
+.macro THREAD_SELF reg
+	# struct pthread is just ahead of TCB
+	sub     \reg, r25, TLS_PRE_TCB_SIZE
+.endm
+
+#endif /* __ASSEMBLER__ */
+
+#endif	/* tls.h */
diff --git a/sysdeps/arc/preconfigure b/sysdeps/arc/preconfigure
new file mode 100644
index 000000000000..d9c5429f4050
--- /dev/null
+++ b/sysdeps/arc/preconfigure
@@ -0,0 +1,15 @@
+case "$machine" in
+arc*)
+  base_machine=arc
+  machine=arc
+
+  gccfloat=`$CC $CFLAGS $CPPFLAGS -E -dM -xc /dev/null | grep __ARC_FPU_| wc -l`
+  if test "$gccfloat" != "0"; then
+    echo "glibc being configured for double precision floating point"
+    with_fp_cond=1
+  else
+    with_fp_cond=0
+  fi
+  ;;
+
+esac
diff --git a/sysdeps/arc/setjmp.S b/sysdeps/arc/setjmp.S
new file mode 100644
index 000000000000..e745f81643e3
--- /dev/null
+++ b/sysdeps/arc/setjmp.S
@@ -0,0 +1,66 @@
+/* setjmp for ARC.
+   Copyright (C) 1991-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+
+#include <sysdep.h>
+
+/* Upon entry r0 = jump buffer into which regs will be saved.  */
+ENTRY (setjmp)
+	b.d	__sigsetjmp
+	mov	r1, 1		; save signals
+END (setjmp)
+
+/* Upon entry r0 = jump buffer into which regs will be saved.  */
+ENTRY (_setjmp)
+	b.d	__sigsetjmp
+	mov	r1, 0		/* don't save signals.  */
+END (_setjmp)
+libc_hidden_def (_setjmp)
+
+/* Upon entry
+   r0 = jump buffer into which regs will be saved
+   r1 = do we need to save signals.  */
+ENTRY (__sigsetjmp)
+
+	st_s r13, [r0]
+	st_s r14, [r0,4]
+	st   r15, [r0,8]
+	st   r16, [r0,12]
+	st   r17, [r0,16]
+	st   r18, [r0,20]
+	st   r19, [r0,24]
+	st   r20, [r0,28]
+	st   r21, [r0,32]
+	st   r22, [r0,36]
+	st   r23, [r0,40]
+	st   r24, [r0,44]
+	st   r25, [r0,48]
+	st   fp,  [r0,52]
+	st   sp,  [r0,56]
+
+	/* Make a note of where longjmp will return to.
+	   that will be right next to this setjmp call-site which will be
+	   contained in blink, since "C" caller of this routine will do
+	   a branch-n-link */
+
+	st   blink, [r0,60]
+	b    __sigjmp_save
+
+END (__sigsetjmp)
+
+libc_hidden_def (__sigsetjmp)
diff --git a/sysdeps/arc/sfp-machine.h b/sysdeps/arc/sfp-machine.h
new file mode 100644
index 000000000000..c58615461deb
--- /dev/null
+++ b/sysdeps/arc/sfp-machine.h
@@ -0,0 +1,73 @@
+/* Machine-dependent software floating-point definitions.  ARC version.
+   Copyright (C) 2004-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+   Contributed by Richard Henderson (rth@cygnus.com),
+		  Jakub Jelinek (jj@ultra.linux.cz) and
+		  David S. Miller (davem@redhat.com).
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+
+#define _FP_W_TYPE_SIZE		32
+#define _FP_W_TYPE		unsigned long
+#define _FP_WS_TYPE		signed long
+#define _FP_I_TYPE		long
+
+#define _FP_MUL_MEAT_S(R,X,Y)				\
+  _FP_MUL_MEAT_1_wide(_FP_WFRACBITS_S,R,X,Y,umul_ppmm)
+#define _FP_MUL_MEAT_D(R,X,Y)				\
+  _FP_MUL_MEAT_2_wide(_FP_WFRACBITS_D,R,X,Y,umul_ppmm)
+#define _FP_MUL_MEAT_Q(R,X,Y)				\
+  _FP_MUL_MEAT_4_wide(_FP_WFRACBITS_Q,R,X,Y,umul_ppmm)
+
+#define _FP_MUL_MEAT_DW_S(R,X,Y)				\
+  _FP_MUL_MEAT_DW_1_wide(_FP_WFRACBITS_S,R,X,Y,umul_ppmm)
+#define _FP_MUL_MEAT_DW_D(R,X,Y)				\
+  _FP_MUL_MEAT_DW_2_wide(_FP_WFRACBITS_D,R,X,Y,umul_ppmm)
+#define _FP_MUL_MEAT_DW_Q(R,X,Y)				\
+  _FP_MUL_MEAT_DW_4_wide(_FP_WFRACBITS_Q,R,X,Y,umul_ppmm)
+
+#define _FP_DIV_MEAT_S(R,X,Y)	_FP_DIV_MEAT_1_loop(S,R,X,Y)
+#define _FP_DIV_MEAT_D(R,X,Y)	_FP_DIV_MEAT_2_udiv(D,R,X,Y)
+#define _FP_DIV_MEAT_Q(R,X,Y)	_FP_DIV_MEAT_4_udiv(Q,R,X,Y)
+
+#define _FP_NANFRAC_S		((_FP_QNANBIT_S << 1) - 1)
+#define _FP_NANFRAC_D		((_FP_QNANBIT_D << 1) - 1), -1
+#define _FP_NANFRAC_Q		((_FP_QNANBIT_Q << 1) - 1), -1, -1, -1
+#define _FP_NANSIGN_S		0
+#define _FP_NANSIGN_D		0
+#define _FP_NANSIGN_Q		0
+
+#define _FP_KEEPNANFRACP 1
+#define _FP_QNANNEGATEDP 0
+
+/* This is arbitrarily taken from the PowerPC version.  */
+#define _FP_CHOOSENAN(fs, wc, R, X, Y, OP)			\
+  do {								\
+    if ((_FP_FRAC_HIGH_RAW_##fs(X) & _FP_QNANBIT_##fs)		\
+	&& !(_FP_FRAC_HIGH_RAW_##fs(Y) & _FP_QNANBIT_##fs))	\
+      {								\
+	R##_s = Y##_s;						\
+	_FP_FRAC_COPY_##wc(R,Y);				\
+      }								\
+    else							\
+      {								\
+	R##_s = X##_s;						\
+	_FP_FRAC_COPY_##wc(R,X);				\
+      }								\
+    R##_c = FP_CLS_NAN;						\
+  } while (0)
+
+#define _FP_TININESS_AFTER_ROUNDING 0
diff --git a/sysdeps/arc/sotruss-lib.c b/sysdeps/arc/sotruss-lib.c
new file mode 100644
index 000000000000..3253d610c5e0
--- /dev/null
+++ b/sysdeps/arc/sotruss-lib.c
@@ -0,0 +1,51 @@
+/* Override generic sotruss-lib.c to define actual functions for ARC.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#define HAVE_ARCH_PLTENTER
+#define HAVE_ARCH_PLTEXIT
+
+#include <elf/sotruss-lib.c>
+
+ElfW(Addr)
+la_arc_gnu_pltenter (ElfW(Sym) *sym __attribute__ ((unused)),
+		       unsigned int ndx __attribute__ ((unused)),
+		       uintptr_t *refcook, uintptr_t *defcook,
+		       La_arc_regs *regs, unsigned int *flags,
+		       const char *symname, long int *framesizep)
+{
+  print_enter (refcook, defcook, symname,
+	       regs->lr_reg[0], regs->lr_reg[1], regs->lr_reg[2],
+	       *flags);
+
+  /* No need to copy anything, we will not need the parameters in any case.  */
+  *framesizep = 0;
+
+  return sym->st_value;
+}
+
+unsigned int
+la_arc_gnu_pltexit (ElfW(Sym) *sym, unsigned int ndx, uintptr_t *refcook,
+		      uintptr_t *defcook,
+		      const struct La_arc_regs *inregs,
+		      struct La_arc_retval *outregs, const char *symname)
+{
+  print_exit (refcook, defcook, symname, outregs->lrv_reg[0]);
+
+  return 0;
+}
diff --git a/sysdeps/arc/stackinfo.h b/sysdeps/arc/stackinfo.h
new file mode 100644
index 000000000000..911efd928675
--- /dev/null
+++ b/sysdeps/arc/stackinfo.h
@@ -0,0 +1,33 @@
+/* Stack environment definitions for ARC.
+   Copyright (C) 2012-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+/* This file contains a bit of information about the stack allocation
+   of the processor.  */
+
+#ifndef _STACKINFO_H
+#define _STACKINFO_H	1
+
+#include <elf.h>
+
+/* On ARC the stack grows down.  */
+#define _STACK_GROWS_DOWN	1
+
+/* Default to a non-executable stack.  */
+#define DEFAULT_STACK_PERMS (PF_R|PF_W)
+
+#endif	/* stackinfo.h */
diff --git a/sysdeps/arc/start.S b/sysdeps/arc/start.S
new file mode 100644
index 000000000000..e006453dcd1f
--- /dev/null
+++ b/sysdeps/arc/start.S
@@ -0,0 +1,71 @@
+/* Startup code for ARC.
+   Copyright (C) 1995-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#define __ASSEMBLY__ 1
+#include <entry.h>
+#ifndef ENTRY_POINT
+# error ENTRY_POINT needs to be defined for ARC
+#endif
+
+/* When we enter this piece of code, the program stack looks like this:
+        argc            argument counter (integer)
+        argv[0]         program name (pointer)
+        argv[1...N]     program args (pointers)
+        argv[argc-1]    end of args (integer)
+	NULL
+        env[0...N]      environment variables (pointers)
+        NULL.  */
+
+	.text
+	.align 4
+	.global __start
+	.type __start,@function
+__start:
+	mov	fp, 0
+	ld_s	r1, [sp]	; argc
+
+	mov_s	r5, r0		; rltd_fini
+	add_s	r2, sp, 4	; argv
+	and	sp, sp, -8
+	mov	r6, sp
+
+	/* __libc_start_main (main, argc, argv, init, fini, rtld_fini, stack_end).  */
+
+#ifdef SHARED
+	ld	r0, [pcl, @main@gotpc]
+	ld	r3, [pcl, @__libc_csu_init@gotpc]
+	ld	r4, [pcl, @__libc_csu_fini@gotpc]
+	bl	__libc_start_main@plt
+#else
+	mov_s	r0, main
+	mov_s	r3, __libc_csu_init
+	mov	r4, __libc_csu_fini
+	bl	__libc_start_main
+#endif
+
+	/* Should never get here.  */
+	flag    1
+	.size  __start,.-__start
+
+/* Define a symbol for the first piece of initialized data.  */
+	.data
+	.globl __data_start
+__data_start:
+	.long 0
+	.weak data_start
+	data_start = __data_start
diff --git a/sysdeps/arc/sysdep.h b/sysdeps/arc/sysdep.h
new file mode 100644
index 000000000000..e94955ed9d5f
--- /dev/null
+++ b/sysdeps/arc/sysdep.h
@@ -0,0 +1,48 @@
+/* Assembler macros for ARC.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public License as
+   published by the Free Software Foundation; either version 2.1 of the
+   License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sysdeps/generic/sysdep.h>
+
+#ifdef	__ASSEMBLER__
+
+/* Syntactic details of assembler.
+   ; is not newline but comment, # is also for comment.  */
+# define ASM_SIZE_DIRECTIVE(name) .size name,.-name
+
+# define ENTRY(name)						\
+	.align 4				ASM_LINE_SEP	\
+	.globl C_SYMBOL_NAME(name)		ASM_LINE_SEP	\
+	.type C_SYMBOL_NAME(name),%function	ASM_LINE_SEP	\
+	C_LABEL(name)				ASM_LINE_SEP	\
+	cfi_startproc				ASM_LINE_SEP	\
+	CALL_MCOUNT
+
+# undef  END
+# define END(name)						\
+	cfi_endproc				ASM_LINE_SEP	\
+	ASM_SIZE_DIRECTIVE(name)
+
+# ifdef SHARED
+#  define PLTJMP(_x)	_x##@plt
+# else
+#  define PLTJMP(_x)	_x
+# endif
+
+# define CALL_MCOUNT		/* Do nothing for now.  */
+
+#endif	/* __ASSEMBLER__ */
diff --git a/sysdeps/arc/tininess.h b/sysdeps/arc/tininess.h
new file mode 100644
index 000000000000..1db37790f881
--- /dev/null
+++ b/sysdeps/arc/tininess.h
@@ -0,0 +1 @@
+#define TININESS_AFTER_ROUNDING	1
diff --git a/sysdeps/arc/tls-macros.h b/sysdeps/arc/tls-macros.h
new file mode 100644
index 000000000000..2793bd9d8a7c
--- /dev/null
+++ b/sysdeps/arc/tls-macros.h
@@ -0,0 +1,47 @@
+/* Macros to support TLS testing in times of missing compiler support.  ARC version.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+
+/* For now.  */
+#define TLS_LD(x)	TLS_IE(x)
+
+#define TLS_GD(x)					\
+  ({ int *__result;					\
+     __asm__ ("add r0, pcl, @" #x "@tlsgd      \n"     	\
+	  ".tls_gd_ld " #x "`bl __tls_get_addr@plt \n"	\
+	  "mov %0, r0                    \n"		\
+	  : "=&r" (__result)				\
+	  ::"r0","r1","r2","r3","r4","r5","r6","r7",	\
+	    "r8","r9","r10","r11","r12");		\
+     __result; })
+
+#define TLS_LE(x)					\
+  ({ int *__result;					\
+     void *tp = __builtin_thread_pointer();		\
+     __asm__ ("add %0, %1, @" #x "@tpoff   \n"		\
+	  : "=r" (__result) : "r"(tp));	        	\
+     __result; })
+
+#define TLS_IE(x)					\
+  ({ int *__result;					\
+     void *tp = __builtin_thread_pointer();		\
+     __asm__ ("ld %0, [pcl, @" #x "@tlsie]      \n"     \
+	  "add %0, %1, %0                       \n"	\
+	  : "=&r" (__result) : "r" (tp));		\
+     __result; })
diff --git a/sysdeps/arc/tst-audit.h b/sysdeps/arc/tst-audit.h
new file mode 100644
index 000000000000..10a20c49c00c
--- /dev/null
+++ b/sysdeps/arc/tst-audit.h
@@ -0,0 +1,23 @@
+/* Definitions for testing PLT entry/exit auditing.  ARC version.
+   Copyright (C) 2009-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#define pltenter la_arc_gnu_pltenter
+#define pltexit la_arc_gnu_pltexit
+#define La_regs La_arc_regs
+#define La_retval La_arc_retval
+#define int_retval lrv_reg[0]
diff --git a/sysdeps/unix/sysv/linux/arc/Implies b/sysdeps/unix/sysv/linux/arc/Implies
new file mode 100644
index 000000000000..7f739a0340b6
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/Implies
@@ -0,0 +1,3 @@
+arc/nptl
+unix/sysv/linux/generic/wordsize-32
+unix/sysv/linux/generic
diff --git a/sysdeps/unix/sysv/linux/arc/Makefile b/sysdeps/unix/sysv/linux/arc/Makefile
new file mode 100644
index 000000000000..a6c6dfc6ec64
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/Makefile
@@ -0,0 +1,20 @@
+ifeq ($(subdir),stdlib)
+gen-as-const-headers += ucontext_i.sym
+endif
+
+ifeq ($(subdir),signal)
+sysdep_routines += sigrestorer
+endif
+
+ifeq ($(subdir),misc)
+# MIPS/Tile-style cacheflush routine
+sysdep_headers += sys/cachectl.h
+sysdep_routines += cacheflush
+endif
+
+ifeq ($(subdir),elf)
+ifeq ($(build-shared),yes)
+# This is needed for DSO loading from static binaries.
+sysdep-dl-routines += dl-static
+endif
+endif
diff --git a/sysdeps/unix/sysv/linux/arc/Versions b/sysdeps/unix/sysv/linux/arc/Versions
new file mode 100644
index 000000000000..292f1974b02a
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/Versions
@@ -0,0 +1,16 @@
+ld {
+  GLIBC_PRIVATE {
+    # used for loading by static libraries
+    _dl_var_init;
+  }
+}
+libc {
+  GLIBC_2.32 {
+    _flush_cache;
+    cacheflush;
+  }
+  GLIBC_PRIVATE {
+    # A copy of sigaction lives in libpthread, and needs these.
+    __default_rt_sa_restorer;
+  }
+}
diff --git a/sysdeps/unix/sysv/linux/arc/arch-syscall.h b/sysdeps/unix/sysv/linux/arc/arch-syscall.h
new file mode 100644
index 000000000000..db25a17ad077
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/arch-syscall.h
@@ -0,0 +1,317 @@
+/* AUTOGENERATED by update-syscall-lists.py.  */
+#define __NR_accept 202
+#define __NR_accept4 242
+#define __NR_acct 89
+#define __NR_add_key 217
+#define __NR_adjtimex 171
+#define __NR_arc_gettls 246
+#define __NR_arc_settls 245
+#define __NR_arc_usr_cmpxchg 248
+#define __NR_bind 200
+#define __NR_bpf 280
+#define __NR_brk 214
+#define __NR_cacheflush 244
+#define __NR_capget 90
+#define __NR_capset 91
+#define __NR_chdir 49
+#define __NR_chroot 51
+#define __NR_clock_adjtime 266
+#define __NR_clock_adjtime64 405
+#define __NR_clock_getres 114
+#define __NR_clock_getres_time64 406
+#define __NR_clock_gettime 113
+#define __NR_clock_gettime64 403
+#define __NR_clock_nanosleep 115
+#define __NR_clock_nanosleep_time64 407
+#define __NR_clock_settime 112
+#define __NR_clock_settime64 404
+#define __NR_clone 220
+#define __NR_clone3 435
+#define __NR_close 57
+#define __NR_connect 203
+#define __NR_copy_file_range 285
+#define __NR_delete_module 106
+#define __NR_dup 23
+#define __NR_dup3 24
+#define __NR_epoll_create1 20
+#define __NR_epoll_ctl 21
+#define __NR_epoll_pwait 22
+#define __NR_eventfd2 19
+#define __NR_execve 221
+#define __NR_execveat 281
+#define __NR_exit 93
+#define __NR_exit_group 94
+#define __NR_faccessat 48
+#define __NR_fadvise64_64 223
+#define __NR_fallocate 47
+#define __NR_fanotify_init 262
+#define __NR_fanotify_mark 263
+#define __NR_fchdir 50
+#define __NR_fchmod 52
+#define __NR_fchmodat 53
+#define __NR_fchown 55
+#define __NR_fchownat 54
+#define __NR_fcntl64 25
+#define __NR_fdatasync 83
+#define __NR_fgetxattr 10
+#define __NR_finit_module 273
+#define __NR_flistxattr 13
+#define __NR_flock 32
+#define __NR_fremovexattr 16
+#define __NR_fsconfig 431
+#define __NR_fsetxattr 7
+#define __NR_fsmount 432
+#define __NR_fsopen 430
+#define __NR_fspick 433
+#define __NR_fstat64 80
+#define __NR_fstatat64 79
+#define __NR_fstatfs64 44
+#define __NR_fsync 82
+#define __NR_ftruncate64 46
+#define __NR_futex 98
+#define __NR_futex_time64 422
+#define __NR_get_mempolicy 236
+#define __NR_get_robust_list 100
+#define __NR_getcpu 168
+#define __NR_getcwd 17
+#define __NR_getdents64 61
+#define __NR_getegid 177
+#define __NR_geteuid 175
+#define __NR_getgid 176
+#define __NR_getgroups 158
+#define __NR_getitimer 102
+#define __NR_getpeername 205
+#define __NR_getpgid 155
+#define __NR_getpid 172
+#define __NR_getppid 173
+#define __NR_getpriority 141
+#define __NR_getrandom 278
+#define __NR_getresgid 150
+#define __NR_getresuid 148
+#define __NR_getrlimit 163
+#define __NR_getrusage 165
+#define __NR_getsid 156
+#define __NR_getsockname 204
+#define __NR_getsockopt 209
+#define __NR_gettid 178
+#define __NR_gettimeofday 169
+#define __NR_getuid 174
+#define __NR_getxattr 8
+#define __NR_init_module 105
+#define __NR_inotify_add_watch 27
+#define __NR_inotify_init1 26
+#define __NR_inotify_rm_watch 28
+#define __NR_io_cancel 3
+#define __NR_io_destroy 1
+#define __NR_io_getevents 4
+#define __NR_io_pgetevents 292
+#define __NR_io_pgetevents_time64 416
+#define __NR_io_setup 0
+#define __NR_io_submit 2
+#define __NR_io_uring_enter 426
+#define __NR_io_uring_register 427
+#define __NR_io_uring_setup 425
+#define __NR_ioctl 29
+#define __NR_ioprio_get 31
+#define __NR_ioprio_set 30
+#define __NR_kcmp 272
+#define __NR_kexec_file_load 294
+#define __NR_kexec_load 104
+#define __NR_keyctl 219
+#define __NR_kill 129
+#define __NR_lgetxattr 9
+#define __NR_linkat 37
+#define __NR_listen 201
+#define __NR_listxattr 11
+#define __NR_llistxattr 12
+#define __NR_llseek 62
+#define __NR_lookup_dcookie 18
+#define __NR_lremovexattr 15
+#define __NR_lsetxattr 6
+#define __NR_madvise 233
+#define __NR_mbind 235
+#define __NR_membarrier 283
+#define __NR_memfd_create 279
+#define __NR_migrate_pages 238
+#define __NR_mincore 232
+#define __NR_mkdirat 34
+#define __NR_mknodat 33
+#define __NR_mlock 228
+#define __NR_mlock2 284
+#define __NR_mlockall 230
+#define __NR_mmap2 222
+#define __NR_mount 40
+#define __NR_move_mount 429
+#define __NR_move_pages 239
+#define __NR_mprotect 226
+#define __NR_mq_getsetattr 185
+#define __NR_mq_notify 184
+#define __NR_mq_open 180
+#define __NR_mq_timedreceive 183
+#define __NR_mq_timedreceive_time64 419
+#define __NR_mq_timedsend 182
+#define __NR_mq_timedsend_time64 418
+#define __NR_mq_unlink 181
+#define __NR_mremap 216
+#define __NR_msgctl 187
+#define __NR_msgget 186
+#define __NR_msgrcv 188
+#define __NR_msgsnd 189
+#define __NR_msync 227
+#define __NR_munlock 229
+#define __NR_munlockall 231
+#define __NR_munmap 215
+#define __NR_name_to_handle_at 264
+#define __NR_nanosleep 101
+#define __NR_nfsservctl 42
+#define __NR_open_by_handle_at 265
+#define __NR_open_tree 428
+#define __NR_openat 56
+#define __NR_perf_event_open 241
+#define __NR_personality 92
+#define __NR_pidfd_open 434
+#define __NR_pidfd_send_signal 424
+#define __NR_pipe2 59
+#define __NR_pivot_root 41
+#define __NR_pkey_alloc 289
+#define __NR_pkey_free 290
+#define __NR_pkey_mprotect 288
+#define __NR_ppoll 73
+#define __NR_ppoll_time64 414
+#define __NR_prctl 167
+#define __NR_pread64 67
+#define __NR_preadv 69
+#define __NR_preadv2 286
+#define __NR_prlimit64 261
+#define __NR_process_vm_readv 270
+#define __NR_process_vm_writev 271
+#define __NR_pselect6 72
+#define __NR_pselect6_time64 413
+#define __NR_ptrace 117
+#define __NR_pwrite64 68
+#define __NR_pwritev 70
+#define __NR_pwritev2 287
+#define __NR_quotactl 60
+#define __NR_read 63
+#define __NR_readahead 213
+#define __NR_readlinkat 78
+#define __NR_readv 65
+#define __NR_reboot 142
+#define __NR_recvfrom 207
+#define __NR_recvmmsg 243
+#define __NR_recvmmsg_time64 417
+#define __NR_recvmsg 212
+#define __NR_remap_file_pages 234
+#define __NR_removexattr 14
+#define __NR_renameat 38
+#define __NR_renameat2 276
+#define __NR_request_key 218
+#define __NR_restart_syscall 128
+#define __NR_rseq 293
+#define __NR_rt_sigaction 134
+#define __NR_rt_sigpending 136
+#define __NR_rt_sigprocmask 135
+#define __NR_rt_sigqueueinfo 138
+#define __NR_rt_sigreturn 139
+#define __NR_rt_sigsuspend 133
+#define __NR_rt_sigtimedwait 137
+#define __NR_rt_sigtimedwait_time64 421
+#define __NR_rt_tgsigqueueinfo 240
+#define __NR_sched_get_priority_max 125
+#define __NR_sched_get_priority_min 126
+#define __NR_sched_getaffinity 123
+#define __NR_sched_getattr 275
+#define __NR_sched_getparam 121
+#define __NR_sched_getscheduler 120
+#define __NR_sched_rr_get_interval 127
+#define __NR_sched_rr_get_interval_time64 423
+#define __NR_sched_setaffinity 122
+#define __NR_sched_setattr 274
+#define __NR_sched_setparam 118
+#define __NR_sched_setscheduler 119
+#define __NR_sched_yield 124
+#define __NR_seccomp 277
+#define __NR_semctl 191
+#define __NR_semget 190
+#define __NR_semop 193
+#define __NR_semtimedop 192
+#define __NR_semtimedop_time64 420
+#define __NR_sendfile64 71
+#define __NR_sendmmsg 269
+#define __NR_sendmsg 211
+#define __NR_sendto 206
+#define __NR_set_mempolicy 237
+#define __NR_set_robust_list 99
+#define __NR_set_tid_address 96
+#define __NR_setdomainname 162
+#define __NR_setfsgid 152
+#define __NR_setfsuid 151
+#define __NR_setgid 144
+#define __NR_setgroups 159
+#define __NR_sethostname 161
+#define __NR_setitimer 103
+#define __NR_setns 268
+#define __NR_setpgid 154
+#define __NR_setpriority 140
+#define __NR_setregid 143
+#define __NR_setresgid 149
+#define __NR_setresuid 147
+#define __NR_setreuid 145
+#define __NR_setrlimit 164
+#define __NR_setsid 157
+#define __NR_setsockopt 208
+#define __NR_settimeofday 170
+#define __NR_setuid 146
+#define __NR_setxattr 5
+#define __NR_shmat 196
+#define __NR_shmctl 195
+#define __NR_shmdt 197
+#define __NR_shmget 194
+#define __NR_shutdown 210
+#define __NR_sigaltstack 132
+#define __NR_signalfd4 74
+#define __NR_socket 198
+#define __NR_socketpair 199
+#define __NR_splice 76
+#define __NR_statfs64 43
+#define __NR_statx 291
+#define __NR_swapoff 225
+#define __NR_swapon 224
+#define __NR_symlinkat 36
+#define __NR_sync 81
+#define __NR_sync_file_range 84
+#define __NR_syncfs 267
+#define __NR_sysfs 247
+#define __NR_sysinfo 179
+#define __NR_syslog 116
+#define __NR_tee 77
+#define __NR_tgkill 131
+#define __NR_timer_create 107
+#define __NR_timer_delete 111
+#define __NR_timer_getoverrun 109
+#define __NR_timer_gettime 108
+#define __NR_timer_gettime64 408
+#define __NR_timer_settime 110
+#define __NR_timer_settime64 409
+#define __NR_timerfd_create 85
+#define __NR_timerfd_gettime 87
+#define __NR_timerfd_gettime64 410
+#define __NR_timerfd_settime 86
+#define __NR_timerfd_settime64 411
+#define __NR_times 153
+#define __NR_tkill 130
+#define __NR_truncate64 45
+#define __NR_umask 166
+#define __NR_umount2 39
+#define __NR_uname 160
+#define __NR_unlinkat 35
+#define __NR_unshare 97
+#define __NR_userfaultfd 282
+#define __NR_utimensat 88
+#define __NR_utimensat_time64 412
+#define __NR_vhangup 58
+#define __NR_vmsplice 75
+#define __NR_wait4 260
+#define __NR_waitid 95
+#define __NR_write 64
+#define __NR_writev 66
diff --git a/sysdeps/unix/sysv/linux/arc/bits/procfs.h b/sysdeps/unix/sysv/linux/arc/bits/procfs.h
new file mode 100644
index 000000000000..e217e94eb6c0
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/bits/procfs.h
@@ -0,0 +1,35 @@
+/* Types for registers for sys/procfs.h.  ARC version.
+   Copyright (C) 1996-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _SYS_PROCFS_H
+# error "Never include <bits/procfs.h> directly; use <sys/procfs.h> instead."
+#endif
+
+#include <sys/ucontext.h>
+
+/* And the whole bunch of them.  We could have used `struct
+   user_regs' directly in the typedef, but tradition says that
+   the register set is an array, which does have some peculiar
+   semantics, so leave it that way.  */
+#define ELF_NGREG (sizeof (struct user_regs_struct) / sizeof(elf_greg_t))
+
+typedef unsigned long int elf_greg_t;
+typedef unsigned long int elf_gregset_t[ELF_NGREG];
+
+/* There's no seperate floating point reg file in ARCv2.  */
+typedef struct { } elf_fpregset_t;
diff --git a/sysdeps/unix/sysv/linux/arc/bits/types/__sigset_t.h b/sysdeps/unix/sysv/linux/arc/bits/types/__sigset_t.h
new file mode 100644
index 000000000000..795638a30bd3
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/bits/types/__sigset_t.h
@@ -0,0 +1,12 @@
+/* Architecture-specific __sigset_t definition.  ARC version.  */
+#ifndef ____sigset_t_defined
+#define ____sigset_t_defined
+
+/* Linux asm-generic syscall ABI expects sigset_t to hold 64 signals.  */
+#define _SIGSET_NWORDS (64 / (8 * sizeof (unsigned long int)))
+typedef struct
+{
+  unsigned long int __val[_SIGSET_NWORDS];
+} __sigset_t;
+
+#endif
diff --git a/sysdeps/unix/sysv/linux/arc/c++-types.data b/sysdeps/unix/sysv/linux/arc/c++-types.data
new file mode 100644
index 000000000000..303f4570c8ee
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/c++-types.data
@@ -0,0 +1,67 @@
+blkcnt64_t:x
+blkcnt_t:l
+blksize_t:i
+caddr_t:Pc
+clockid_t:i
+clock_t:l
+daddr_t:i
+dev_t:y
+fd_mask:l
+fsblkcnt64_t:y
+fsblkcnt_t:m
+fsfilcnt64_t:y
+fsfilcnt_t:m
+fsid_t:8__fsid_t
+gid_t:j
+id_t:j
+ino64_t:y
+ino_t:m
+int16_t:s
+int32_t:i
+int64_t:x
+int8_t:a
+intptr_t:i
+key_t:i
+loff_t:x
+mode_t:j
+nlink_t:j
+off64_t:x
+off_t:l
+pid_t:i
+pthread_attr_t:14pthread_attr_t
+pthread_barrier_t:17pthread_barrier_t
+pthread_barrierattr_t:21pthread_barrierattr_t
+pthread_cond_t:14pthread_cond_t
+pthread_condattr_t:18pthread_condattr_t
+pthread_key_t:j
+pthread_mutex_t:15pthread_mutex_t
+pthread_mutexattr_t:19pthread_mutexattr_t
+pthread_once_t:i
+pthread_rwlock_t:16pthread_rwlock_t
+pthread_rwlockattr_t:20pthread_rwlockattr_t
+pthread_spinlock_t:i
+pthread_t:m
+quad_t:x
+register_t:i
+rlim64_t:y
+rlim_t:m
+sigset_t:10__sigset_t
+size_t:j
+socklen_t:j
+ssize_t:i
+suseconds_t:l
+time_t:l
+u_char:h
+uid_t:j
+uint:j
+u_int:j
+u_int16_t:t
+u_int32_t:j
+u_int64_t:y
+u_int8_t:h
+ulong:m
+u_long:m
+u_quad_t:y
+useconds_t:j
+ushort:t
+u_short:t
diff --git a/sysdeps/unix/sysv/linux/arc/clone.S b/sysdeps/unix/sysv/linux/arc/clone.S
new file mode 100644
index 000000000000..c5ba38541163
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/clone.S
@@ -0,0 +1,98 @@
+/* clone() implementation for ARC.
+   Copyright (C) 2008-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+   Contributed by Andrew Jenner <andrew@codesourcery.com>, 2008.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+
+#include <sysdep.h>
+#define _ERRNO_H	1
+#include <bits/errno.h>
+#include <tcb-offsets.h>
+
+#define CLONE_SETTLS		0x00080000
+
+/* int clone(int (*fn)(void *), void *child_stack,
+           int flags, void *arg, ...
+           < pid_t *ptid, struct user_desc *tls, pid_t *ctid > );
+
+ NOTE: I'm assuming that the last 3 args are NOT var-args and in case all
+	3 are not relevant, caller will nevertheless pass those as NULL.
+
+ clone syscall in kernel (ABI: CONFIG_CLONE_BACKWARDS)
+
+  int sys_clone(unsigned long int clone_flags,
+	        unsigned long int newsp,
+		int __user *parent_tidptr,
+		void *tls,
+		int __user *child_tidptr).  */
+
+ENTRY (__clone)
+	cmp	r0, 0		; @fn can't be NULL
+	cmp.ne	r1, 0		; @child_stack can't be NULL
+	bz	.L__sys_err
+
+	; save some of the orig args
+	; r0 containg @fn will be clobbered AFTER syscall (with ret val)
+	; rest are clobbered BEFORE syscall due to different arg ordering
+	mov	r10, r0		; @fn
+	mov	r11, r3		; @args
+	mov	r12, r2		; @clone_flags
+	mov	r9,  r5		; @tls
+
+	; adjust libc args for syscall
+
+	mov 	r0, r2		; libc @flags is 1st syscall arg
+	mov	r2, r4		; libc @ptid
+	mov	r3, r5		; libc @tls
+	mov	r4, r6		; libc @ctid
+	mov	r8, __NR_clone
+	ARC_TRAP_INSN
+
+	cmp	r0, 0		; return code : 0 new process, !0 parent
+	blt	.L__sys_err2	; < 0 (signed) error
+	jnz	[blink]		; Parent returns
+
+	; ----- child starts here ---------
+
+	; Setup TP register (only recent kernels v4.19+ do that)
+	and.f	0, r12, CLONE_SETTLS
+	mov.nz	r25, r9
+
+	; child jumps off to @fn with @arg as argument, and returns here
+	jl.d	[r10]
+	mov	r0, r11
+
+	; exit() with result from @fn (already in r0)
+	mov	r8, __NR_exit
+	ARC_TRAP_INSN
+	; In case it ever came back
+	flag	1
+
+.L__sys_err:
+	mov	r0, -EINVAL
+.L__sys_err2:
+	; (1) No need to make -ve kernel error code as positive errno
+	;   __syscall_error expects the -ve error code returned by kernel
+	; (2) r0 still had orig -ve kernel error code
+	; (3) Tail call to __syscall_error so we dont have to come back
+	;     here hence instead of jmp-n-link (reg push/pop) we do jmp
+	; (4) No need to route __syscall_error via PLT, B is inherently
+	;     position independent
+	b   __syscall_error
+PSEUDO_END (__clone)
+libc_hidden_def (__clone)
+weak_alias (__clone, clone)
diff --git a/sysdeps/unix/sysv/linux/arc/configure b/sysdeps/unix/sysv/linux/arc/configure
new file mode 100644
index 000000000000..f74fa7cb0259
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/configure
@@ -0,0 +1,4 @@
+# This file is generated from configure.in by Autoconf.  DO NOT EDIT!
+ # Local configure fragment for sysdeps/unix/sysv/linux/arc.
+
+arch_minimum_kernel=3.9.0
diff --git a/sysdeps/unix/sysv/linux/arc/configure.ac b/sysdeps/unix/sysv/linux/arc/configure.ac
new file mode 100644
index 000000000000..a9528032d32a
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/configure.ac
@@ -0,0 +1,4 @@
+GLIBC_PROVIDES dnl See aclocal.m4 in the top level source directory.
+# Local configure fragment for sysdeps/unix/sysv/linux/arc.
+
+arch_minimum_kernel=3.9.0
diff --git a/sysdeps/unix/sysv/linux/arc/dl-static.c b/sysdeps/unix/sysv/linux/arc/dl-static.c
new file mode 100644
index 000000000000..24c31b27fc11
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/dl-static.c
@@ -0,0 +1,84 @@
+/* Variable initialization.  ARC version.
+   Copyright (C) 2001-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <ldsodefs.h>
+
+#ifdef SHARED
+
+void
+_dl_var_init (void *array[])
+{
+  /* It has to match "variables" below. */
+  enum
+    {
+      DL_PAGESIZE = 0
+    };
+
+  GLRO(dl_pagesize) = *((size_t *) array[DL_PAGESIZE]);
+}
+
+#else
+
+static void *variables[] =
+{
+  &GLRO(dl_pagesize)
+};
+
+static void
+_dl_unprotect_relro (struct link_map *l)
+{
+  ElfW(Addr) start = ((l->l_addr + l->l_relro_addr)
+		      & ~(GLRO(dl_pagesize) - 1));
+  ElfW(Addr) end = ((l->l_addr + l->l_relro_addr + l->l_relro_size)
+		    & ~(GLRO(dl_pagesize) - 1));
+
+  if (start != end)
+    __mprotect ((void *) start, end - start, PROT_READ | PROT_WRITE);
+}
+
+void
+_dl_static_init (struct link_map *l)
+{
+  struct link_map *rtld_map = l;
+  struct r_scope_elem **scope;
+  const ElfW(Sym) *ref = NULL;
+  lookup_t loadbase;
+  void (*f) (void *[]);
+  size_t i;
+
+  loadbase = _dl_lookup_symbol_x ("_dl_var_init", l, &ref, l->l_local_scope,
+				  NULL, 0, 1, NULL);
+
+  for (scope = l->l_local_scope; *scope != NULL; scope++)
+    for (i = 0; i < (*scope)->r_nlist; i++)
+      if ((*scope)->r_list[i] == loadbase)
+	{
+	  rtld_map = (*scope)->r_list[i];
+	  break;
+	}
+
+  if (ref != NULL)
+    {
+      f = (void (*) (void *[])) DL_SYMBOL_ADDRESS (loadbase, ref);
+      _dl_unprotect_relro (rtld_map);
+      f (variables);
+      _dl_protect_relro (rtld_map);
+    }
+}
+
+#endif
diff --git a/sysdeps/unix/sysv/linux/arc/getcontext.S b/sysdeps/unix/sysv/linux/arc/getcontext.S
new file mode 100644
index 000000000000..e00aeb1a6931
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/getcontext.S
@@ -0,0 +1,63 @@
+/* Save current context for ARC.
+   Copyright (C) 2009-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include "ucontext-macros.h"
+
+/* int getcontext (ucontext_t *ucp)
+   Save machine context in @ucp and return 0 on success, -1 on error
+    - saves callee saved registers only
+    - layout mandated by uncontext_t:m_context (hence different from setjmp).  */
+
+ENTRY (__getcontext)
+
+	/* Callee saved registers.  */
+	SAVE_REG (r13,   r0, 37)
+	SAVE_REG (r14,   r0, 36)
+	SAVE_REG (r15,   r0, 35)
+	SAVE_REG (r16,   r0, 34)
+	SAVE_REG (r17,   r0, 33)
+	SAVE_REG (r18,   r0, 32)
+	SAVE_REG (r19,   r0, 31)
+	SAVE_REG (r20,   r0, 30)
+	SAVE_REG (r21,   r0, 29)
+	SAVE_REG (r22,   r0, 28)
+	SAVE_REG (r23,   r0, 27)
+	SAVE_REG (r24,   r0, 26)
+	SAVE_REG (r25,   r0, 25)
+
+	SAVE_REG (blink, r0,  7)
+	SAVE_REG (fp,    r0,  8)
+	SAVE_REG (sp,    r0, 23)
+
+	/* Save 0 in r0 placeholder to return 0 when this @ucp activated.  */
+	mov r9, 0
+	SAVE_REG (r9,    r0, 22)
+
+	/* rt_sigprocmask (SIG_BLOCK, NULL, &ucp->uc_sigmask, _NSIG8).  */
+	mov r3, _NSIG8
+	add r2, r0, UCONTEXT_SIGMASK
+	mov r1, 0
+	mov r0, SIG_BLOCK
+	mov r8, __NR_rt_sigprocmask
+	ARC_TRAP_INSN
+	brhi    r0, -1024, .Lcall_syscall_err
+	j.d	[blink]
+	mov r0, 0	/* Success, error handled in .Lcall_syscall_err.  */
+
+PSEUDO_END (__getcontext)
+weak_alias (__getcontext, getcontext)
diff --git a/sysdeps/unix/sysv/linux/arc/jmp_buf-macros.h b/sysdeps/unix/sysv/linux/arc/jmp_buf-macros.h
new file mode 100644
index 000000000000..6c129398483a
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/jmp_buf-macros.h
@@ -0,0 +1,6 @@
+#define JMP_BUF_SIZE		(32 + 1 + 64/(8 * sizeof (unsigned long int))) * sizeof (unsigned long int)
+#define SIGJMP_BUF_SIZE		(32 + 1 + 64/(8 * sizeof (unsigned long int))) * sizeof (unsigned long int)
+#define JMP_BUF_ALIGN		__alignof__ (unsigned long int)
+#define SIGJMP_BUF_ALIGN	__alignof__ (unsigned long int)
+#define MASK_WAS_SAVED_OFFSET	(32 * sizeof (unsigned long int))
+#define SAVED_MASK_OFFSET	(33 * sizeof (unsigned long int))
diff --git a/sysdeps/unix/sysv/linux/arc/kernel-features.h b/sysdeps/unix/sysv/linux/arc/kernel-features.h
new file mode 100644
index 000000000000..c038764e62a4
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/kernel-features.h
@@ -0,0 +1,28 @@
+/* Set flags signalling availability of kernel features based on given
+   kernel version number.
+
+   Copyright (C) 2009-2020 Free Software Foundation, Inc.
+
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+/* The minimum supported kernel version for ARC is 3.9,
+   guaranteeing many kernel features.  */
+
+#include_next <kernel-features.h>
+
+#undef __ASSUME_CLONE_DEFAULT
+#define __ASSUME_CLONE_BACKWARDS 1
diff --git a/sysdeps/unix/sysv/linux/arc/ld.abilist b/sysdeps/unix/sysv/linux/arc/ld.abilist
new file mode 100644
index 000000000000..ed2c9b46ecfc
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/ld.abilist
@@ -0,0 +1,9 @@
+GLIBC_2.32 __libc_stack_end D 0x4
+GLIBC_2.32 __stack_chk_guard D 0x4
+GLIBC_2.32 __tls_get_addr F
+GLIBC_2.32 _dl_mcount F
+GLIBC_2.32 _r_debug D 0x14
+GLIBC_2.32 calloc F
+GLIBC_2.32 free F
+GLIBC_2.32 malloc F
+GLIBC_2.32 realloc F
diff --git a/sysdeps/unix/sysv/linux/arc/ldsodefs.h b/sysdeps/unix/sysv/linux/arc/ldsodefs.h
new file mode 100644
index 000000000000..9eef836168be
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/ldsodefs.h
@@ -0,0 +1,32 @@
+/* Run-time dynamic linker data structures for loaded ELF shared objects. ARC
+   Copyright (C) 2001-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef	_LDSODEFS_H
+
+/* Get the real definitions.  */
+#include_next <ldsodefs.h>
+
+/* Now define our stuff.  */
+
+/* We need special support to initialize DSO loaded for statically linked
+   binaries.  */
+extern void _dl_static_init (struct link_map *map);
+#undef DL_STATIC_INIT
+#define DL_STATIC_INIT(map) _dl_static_init (map)
+
+#endif /* ldsodefs.h */
diff --git a/sysdeps/unix/sysv/linux/arc/libBrokenLocale.abilist b/sysdeps/unix/sysv/linux/arc/libBrokenLocale.abilist
new file mode 100644
index 000000000000..b0869cec1fb8
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libBrokenLocale.abilist
@@ -0,0 +1 @@
+GLIBC_2.32 __ctype_get_mb_cur_max F
diff --git a/sysdeps/unix/sysv/linux/arc/libanl.abilist b/sysdeps/unix/sysv/linux/arc/libanl.abilist
new file mode 100644
index 000000000000..ba513bd0289d
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libanl.abilist
@@ -0,0 +1,4 @@
+GLIBC_2.32 gai_cancel F
+GLIBC_2.32 gai_error F
+GLIBC_2.32 gai_suspend F
+GLIBC_2.32 getaddrinfo_a F
diff --git a/sysdeps/unix/sysv/linux/arc/libc.abilist b/sysdeps/unix/sysv/linux/arc/libc.abilist
new file mode 100644
index 000000000000..89d02936fc72
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libc.abilist
@@ -0,0 +1,2084 @@
+GLIBC_2.32 _Exit F
+GLIBC_2.32 _IO_2_1_stderr_ D 0x98
+GLIBC_2.32 _IO_2_1_stdin_ D 0x98
+GLIBC_2.32 _IO_2_1_stdout_ D 0x98
+GLIBC_2.32 _IO_adjust_column F
+GLIBC_2.32 _IO_adjust_wcolumn F
+GLIBC_2.32 _IO_default_doallocate F
+GLIBC_2.32 _IO_default_finish F
+GLIBC_2.32 _IO_default_pbackfail F
+GLIBC_2.32 _IO_default_uflow F
+GLIBC_2.32 _IO_default_xsgetn F
+GLIBC_2.32 _IO_default_xsputn F
+GLIBC_2.32 _IO_do_write F
+GLIBC_2.32 _IO_doallocbuf F
+GLIBC_2.32 _IO_fclose F
+GLIBC_2.32 _IO_fdopen F
+GLIBC_2.32 _IO_feof F
+GLIBC_2.32 _IO_ferror F
+GLIBC_2.32 _IO_fflush F
+GLIBC_2.32 _IO_fgetpos F
+GLIBC_2.32 _IO_fgetpos64 F
+GLIBC_2.32 _IO_fgets F
+GLIBC_2.32 _IO_file_attach F
+GLIBC_2.32 _IO_file_close F
+GLIBC_2.32 _IO_file_close_it F
+GLIBC_2.32 _IO_file_doallocate F
+GLIBC_2.32 _IO_file_finish F
+GLIBC_2.32 _IO_file_fopen F
+GLIBC_2.32 _IO_file_init F
+GLIBC_2.32 _IO_file_jumps D 0x54
+GLIBC_2.32 _IO_file_open F
+GLIBC_2.32 _IO_file_overflow F
+GLIBC_2.32 _IO_file_read F
+GLIBC_2.32 _IO_file_seek F
+GLIBC_2.32 _IO_file_seekoff F
+GLIBC_2.32 _IO_file_setbuf F
+GLIBC_2.32 _IO_file_stat F
+GLIBC_2.32 _IO_file_sync F
+GLIBC_2.32 _IO_file_underflow F
+GLIBC_2.32 _IO_file_write F
+GLIBC_2.32 _IO_file_xsputn F
+GLIBC_2.32 _IO_flockfile F
+GLIBC_2.32 _IO_flush_all F
+GLIBC_2.32 _IO_flush_all_linebuffered F
+GLIBC_2.32 _IO_fopen F
+GLIBC_2.32 _IO_fprintf F
+GLIBC_2.32 _IO_fputs F
+GLIBC_2.32 _IO_fread F
+GLIBC_2.32 _IO_free_backup_area F
+GLIBC_2.32 _IO_free_wbackup_area F
+GLIBC_2.32 _IO_fsetpos F
+GLIBC_2.32 _IO_fsetpos64 F
+GLIBC_2.32 _IO_ftell F
+GLIBC_2.32 _IO_ftrylockfile F
+GLIBC_2.32 _IO_funlockfile F
+GLIBC_2.32 _IO_fwrite F
+GLIBC_2.32 _IO_getc F
+GLIBC_2.32 _IO_getline F
+GLIBC_2.32 _IO_getline_info F
+GLIBC_2.32 _IO_gets F
+GLIBC_2.32 _IO_init F
+GLIBC_2.32 _IO_init_marker F
+GLIBC_2.32 _IO_init_wmarker F
+GLIBC_2.32 _IO_iter_begin F
+GLIBC_2.32 _IO_iter_end F
+GLIBC_2.32 _IO_iter_file F
+GLIBC_2.32 _IO_iter_next F
+GLIBC_2.32 _IO_least_wmarker F
+GLIBC_2.32 _IO_link_in F
+GLIBC_2.32 _IO_list_all D 0x4
+GLIBC_2.32 _IO_list_lock F
+GLIBC_2.32 _IO_list_resetlock F
+GLIBC_2.32 _IO_list_unlock F
+GLIBC_2.32 _IO_marker_delta F
+GLIBC_2.32 _IO_marker_difference F
+GLIBC_2.32 _IO_padn F
+GLIBC_2.32 _IO_peekc_locked F
+GLIBC_2.32 _IO_popen F
+GLIBC_2.32 _IO_printf F
+GLIBC_2.32 _IO_proc_close F
+GLIBC_2.32 _IO_proc_open F
+GLIBC_2.32 _IO_putc F
+GLIBC_2.32 _IO_puts F
+GLIBC_2.32 _IO_remove_marker F
+GLIBC_2.32 _IO_seekmark F
+GLIBC_2.32 _IO_seekoff F
+GLIBC_2.32 _IO_seekpos F
+GLIBC_2.32 _IO_seekwmark F
+GLIBC_2.32 _IO_setb F
+GLIBC_2.32 _IO_setbuffer F
+GLIBC_2.32 _IO_setvbuf F
+GLIBC_2.32 _IO_sgetn F
+GLIBC_2.32 _IO_sprintf F
+GLIBC_2.32 _IO_sputbackc F
+GLIBC_2.32 _IO_sputbackwc F
+GLIBC_2.32 _IO_sscanf F
+GLIBC_2.32 _IO_str_init_readonly F
+GLIBC_2.32 _IO_str_init_static F
+GLIBC_2.32 _IO_str_overflow F
+GLIBC_2.32 _IO_str_pbackfail F
+GLIBC_2.32 _IO_str_seekoff F
+GLIBC_2.32 _IO_str_underflow F
+GLIBC_2.32 _IO_sungetc F
+GLIBC_2.32 _IO_sungetwc F
+GLIBC_2.32 _IO_switch_to_get_mode F
+GLIBC_2.32 _IO_switch_to_main_wget_area F
+GLIBC_2.32 _IO_switch_to_wbackup_area F
+GLIBC_2.32 _IO_switch_to_wget_mode F
+GLIBC_2.32 _IO_un_link F
+GLIBC_2.32 _IO_ungetc F
+GLIBC_2.32 _IO_unsave_markers F
+GLIBC_2.32 _IO_unsave_wmarkers F
+GLIBC_2.32 _IO_vfprintf F
+GLIBC_2.32 _IO_vsprintf F
+GLIBC_2.32 _IO_wdefault_doallocate F
+GLIBC_2.32 _IO_wdefault_finish F
+GLIBC_2.32 _IO_wdefault_pbackfail F
+GLIBC_2.32 _IO_wdefault_uflow F
+GLIBC_2.32 _IO_wdefault_xsgetn F
+GLIBC_2.32 _IO_wdefault_xsputn F
+GLIBC_2.32 _IO_wdo_write F
+GLIBC_2.32 _IO_wdoallocbuf F
+GLIBC_2.32 _IO_wfile_jumps D 0x54
+GLIBC_2.32 _IO_wfile_overflow F
+GLIBC_2.32 _IO_wfile_seekoff F
+GLIBC_2.32 _IO_wfile_sync F
+GLIBC_2.32 _IO_wfile_underflow F
+GLIBC_2.32 _IO_wfile_xsputn F
+GLIBC_2.32 _IO_wmarker_delta F
+GLIBC_2.32 _IO_wsetb F
+GLIBC_2.32 ___brk_addr D 0x4
+GLIBC_2.32 __adjtimex F
+GLIBC_2.32 __after_morecore_hook D 0x4
+GLIBC_2.32 __argz_count F
+GLIBC_2.32 __argz_next F
+GLIBC_2.32 __argz_stringify F
+GLIBC_2.32 __asprintf F
+GLIBC_2.32 __asprintf_chk F
+GLIBC_2.32 __assert F
+GLIBC_2.32 __assert_fail F
+GLIBC_2.32 __assert_perror_fail F
+GLIBC_2.32 __backtrace F
+GLIBC_2.32 __backtrace_symbols F
+GLIBC_2.32 __backtrace_symbols_fd F
+GLIBC_2.32 __bsd_getpgrp F
+GLIBC_2.32 __bzero F
+GLIBC_2.32 __check_rhosts_file D 0x4
+GLIBC_2.32 __chk_fail F
+GLIBC_2.32 __clone F
+GLIBC_2.32 __close F
+GLIBC_2.32 __cmsg_nxthdr F
+GLIBC_2.32 __confstr_chk F
+GLIBC_2.32 __connect F
+GLIBC_2.32 __ctype_b_loc F
+GLIBC_2.32 __ctype_get_mb_cur_max F
+GLIBC_2.32 __ctype_tolower_loc F
+GLIBC_2.32 __ctype_toupper_loc F
+GLIBC_2.32 __curbrk D 0x4
+GLIBC_2.32 __cxa_at_quick_exit F
+GLIBC_2.32 __cxa_atexit F
+GLIBC_2.32 __cxa_finalize F
+GLIBC_2.32 __cxa_thread_atexit_impl F
+GLIBC_2.32 __cyg_profile_func_enter F
+GLIBC_2.32 __cyg_profile_func_exit F
+GLIBC_2.32 __daylight D 0x4
+GLIBC_2.32 __dcgettext F
+GLIBC_2.32 __default_morecore F
+GLIBC_2.32 __dgettext F
+GLIBC_2.32 __dprintf_chk F
+GLIBC_2.32 __dup2 F
+GLIBC_2.32 __duplocale F
+GLIBC_2.32 __endmntent F
+GLIBC_2.32 __environ D 0x4
+GLIBC_2.32 __errno_location F
+GLIBC_2.32 __explicit_bzero_chk F
+GLIBC_2.32 __fbufsize F
+GLIBC_2.32 __fcntl F
+GLIBC_2.32 __fdelt_chk F
+GLIBC_2.32 __fdelt_warn F
+GLIBC_2.32 __ffs F
+GLIBC_2.32 __fgets_chk F
+GLIBC_2.32 __fgets_unlocked_chk F
+GLIBC_2.32 __fgetws_chk F
+GLIBC_2.32 __fgetws_unlocked_chk F
+GLIBC_2.32 __finite F
+GLIBC_2.32 __finitef F
+GLIBC_2.32 __flbf F
+GLIBC_2.32 __fork F
+GLIBC_2.32 __fpending F
+GLIBC_2.32 __fprintf_chk F
+GLIBC_2.32 __fpu_control D 0x4
+GLIBC_2.32 __fpurge F
+GLIBC_2.32 __fread_chk F
+GLIBC_2.32 __fread_unlocked_chk F
+GLIBC_2.32 __freadable F
+GLIBC_2.32 __freading F
+GLIBC_2.32 __free_hook D 0x4
+GLIBC_2.32 __freelocale F
+GLIBC_2.32 __fsetlocking F
+GLIBC_2.32 __fwprintf_chk F
+GLIBC_2.32 __fwritable F
+GLIBC_2.32 __fwriting F
+GLIBC_2.32 __fxstat F
+GLIBC_2.32 __fxstat64 F
+GLIBC_2.32 __fxstatat F
+GLIBC_2.32 __fxstatat64 F
+GLIBC_2.32 __getauxval F
+GLIBC_2.32 __getcwd_chk F
+GLIBC_2.32 __getdelim F
+GLIBC_2.32 __getdomainname_chk F
+GLIBC_2.32 __getgroups_chk F
+GLIBC_2.32 __gethostname_chk F
+GLIBC_2.32 __getlogin_r_chk F
+GLIBC_2.32 __getmntent_r F
+GLIBC_2.32 __getpagesize F
+GLIBC_2.32 __getpgid F
+GLIBC_2.32 __getpid F
+GLIBC_2.32 __gets_chk F
+GLIBC_2.32 __gettimeofday F
+GLIBC_2.32 __getwd_chk F
+GLIBC_2.32 __gmtime_r F
+GLIBC_2.32 __h_errno_location F
+GLIBC_2.32 __isalnum_l F
+GLIBC_2.32 __isalpha_l F
+GLIBC_2.32 __isascii_l F
+GLIBC_2.32 __isblank_l F
+GLIBC_2.32 __iscntrl_l F
+GLIBC_2.32 __isctype F
+GLIBC_2.32 __isdigit_l F
+GLIBC_2.32 __isgraph_l F
+GLIBC_2.32 __isinf F
+GLIBC_2.32 __isinff F
+GLIBC_2.32 __islower_l F
+GLIBC_2.32 __isnan F
+GLIBC_2.32 __isnanf F
+GLIBC_2.32 __isoc99_fscanf F
+GLIBC_2.32 __isoc99_fwscanf F
+GLIBC_2.32 __isoc99_scanf F
+GLIBC_2.32 __isoc99_sscanf F
+GLIBC_2.32 __isoc99_swscanf F
+GLIBC_2.32 __isoc99_vfscanf F
+GLIBC_2.32 __isoc99_vfwscanf F
+GLIBC_2.32 __isoc99_vscanf F
+GLIBC_2.32 __isoc99_vsscanf F
+GLIBC_2.32 __isoc99_vswscanf F
+GLIBC_2.32 __isoc99_vwscanf F
+GLIBC_2.32 __isoc99_wscanf F
+GLIBC_2.32 __isprint_l F
+GLIBC_2.32 __ispunct_l F
+GLIBC_2.32 __isspace_l F
+GLIBC_2.32 __isupper_l F
+GLIBC_2.32 __iswalnum_l F
+GLIBC_2.32 __iswalpha_l F
+GLIBC_2.32 __iswblank_l F
+GLIBC_2.32 __iswcntrl_l F
+GLIBC_2.32 __iswctype F
+GLIBC_2.32 __iswctype_l F
+GLIBC_2.32 __iswdigit_l F
+GLIBC_2.32 __iswgraph_l F
+GLIBC_2.32 __iswlower_l F
+GLIBC_2.32 __iswprint_l F
+GLIBC_2.32 __iswpunct_l F
+GLIBC_2.32 __iswspace_l F
+GLIBC_2.32 __iswupper_l F
+GLIBC_2.32 __iswxdigit_l F
+GLIBC_2.32 __isxdigit_l F
+GLIBC_2.32 __ivaliduser F
+GLIBC_2.32 __key_decryptsession_pk_LOCAL D 0x4
+GLIBC_2.32 __key_encryptsession_pk_LOCAL D 0x4
+GLIBC_2.32 __key_gendes_LOCAL D 0x4
+GLIBC_2.32 __libc_allocate_rtsig F
+GLIBC_2.32 __libc_calloc F
+GLIBC_2.32 __libc_current_sigrtmax F
+GLIBC_2.32 __libc_current_sigrtmin F
+GLIBC_2.32 __libc_free F
+GLIBC_2.32 __libc_freeres F
+GLIBC_2.32 __libc_init_first F
+GLIBC_2.32 __libc_mallinfo F
+GLIBC_2.32 __libc_malloc F
+GLIBC_2.32 __libc_mallopt F
+GLIBC_2.32 __libc_memalign F
+GLIBC_2.32 __libc_pvalloc F
+GLIBC_2.32 __libc_realloc F
+GLIBC_2.32 __libc_sa_len F
+GLIBC_2.32 __libc_start_main F
+GLIBC_2.32 __libc_valloc F
+GLIBC_2.32 __longjmp_chk F
+GLIBC_2.32 __lseek F
+GLIBC_2.32 __lxstat F
+GLIBC_2.32 __lxstat64 F
+GLIBC_2.32 __malloc_hook D 0x4
+GLIBC_2.32 __mbrlen F
+GLIBC_2.32 __mbrtowc F
+GLIBC_2.32 __mbsnrtowcs_chk F
+GLIBC_2.32 __mbsrtowcs_chk F
+GLIBC_2.32 __mbstowcs_chk F
+GLIBC_2.32 __memalign_hook D 0x4
+GLIBC_2.32 __memcpy_chk F
+GLIBC_2.32 __memmove_chk F
+GLIBC_2.32 __mempcpy F
+GLIBC_2.32 __mempcpy_chk F
+GLIBC_2.32 __memset_chk F
+GLIBC_2.32 __monstartup F
+GLIBC_2.32 __morecore D 0x4
+GLIBC_2.32 __nanosleep F
+GLIBC_2.32 __newlocale F
+GLIBC_2.32 __nl_langinfo_l F
+GLIBC_2.32 __nss_configure_lookup F
+GLIBC_2.32 __nss_hostname_digits_dots F
+GLIBC_2.32 __obstack_printf_chk F
+GLIBC_2.32 __obstack_vprintf_chk F
+GLIBC_2.32 __open F
+GLIBC_2.32 __open64 F
+GLIBC_2.32 __open64_2 F
+GLIBC_2.32 __open_2 F
+GLIBC_2.32 __openat64_2 F
+GLIBC_2.32 __openat_2 F
+GLIBC_2.32 __overflow F
+GLIBC_2.32 __pipe F
+GLIBC_2.32 __poll F
+GLIBC_2.32 __poll_chk F
+GLIBC_2.32 __posix_getopt F
+GLIBC_2.32 __ppoll_chk F
+GLIBC_2.32 __pread64 F
+GLIBC_2.32 __pread64_chk F
+GLIBC_2.32 __pread_chk F
+GLIBC_2.32 __printf_chk F
+GLIBC_2.32 __printf_fp F
+GLIBC_2.32 __profile_frequency F
+GLIBC_2.32 __progname D 0x4
+GLIBC_2.32 __progname_full D 0x4
+GLIBC_2.32 __ptsname_r_chk F
+GLIBC_2.32 __pwrite64 F
+GLIBC_2.32 __rawmemchr F
+GLIBC_2.32 __rcmd_errstr D 0x4
+GLIBC_2.32 __read F
+GLIBC_2.32 __read_chk F
+GLIBC_2.32 __readlink_chk F
+GLIBC_2.32 __readlinkat_chk F
+GLIBC_2.32 __realloc_hook D 0x4
+GLIBC_2.32 __realpath_chk F
+GLIBC_2.32 __recv_chk F
+GLIBC_2.32 __recvfrom_chk F
+GLIBC_2.32 __register_atfork F
+GLIBC_2.32 __res_init F
+GLIBC_2.32 __res_nclose F
+GLIBC_2.32 __res_ninit F
+GLIBC_2.32 __res_randomid F
+GLIBC_2.32 __res_state F
+GLIBC_2.32 __rpc_thread_createerr F
+GLIBC_2.32 __rpc_thread_svc_fdset F
+GLIBC_2.32 __rpc_thread_svc_max_pollfd F
+GLIBC_2.32 __rpc_thread_svc_pollfd F
+GLIBC_2.32 __sbrk F
+GLIBC_2.32 __sched_cpualloc F
+GLIBC_2.32 __sched_cpucount F
+GLIBC_2.32 __sched_cpufree F
+GLIBC_2.32 __sched_get_priority_max F
+GLIBC_2.32 __sched_get_priority_min F
+GLIBC_2.32 __sched_getparam F
+GLIBC_2.32 __sched_getscheduler F
+GLIBC_2.32 __sched_setscheduler F
+GLIBC_2.32 __sched_yield F
+GLIBC_2.32 __select F
+GLIBC_2.32 __send F
+GLIBC_2.32 __setmntent F
+GLIBC_2.32 __setpgid F
+GLIBC_2.32 __sigaction F
+GLIBC_2.32 __signbit F
+GLIBC_2.32 __signbitf F
+GLIBC_2.32 __sigpause F
+GLIBC_2.32 __sigsetjmp F
+GLIBC_2.32 __sigsuspend F
+GLIBC_2.32 __snprintf_chk F
+GLIBC_2.32 __sprintf_chk F
+GLIBC_2.32 __stack_chk_fail F
+GLIBC_2.32 __statfs F
+GLIBC_2.32 __stpcpy F
+GLIBC_2.32 __stpcpy_chk F
+GLIBC_2.32 __stpncpy F
+GLIBC_2.32 __stpncpy_chk F
+GLIBC_2.32 __strcasecmp F
+GLIBC_2.32 __strcasecmp_l F
+GLIBC_2.32 __strcasestr F
+GLIBC_2.32 __strcat_chk F
+GLIBC_2.32 __strcoll_l F
+GLIBC_2.32 __strcpy_chk F
+GLIBC_2.32 __strdup F
+GLIBC_2.32 __strerror_r F
+GLIBC_2.32 __strfmon_l F
+GLIBC_2.32 __strftime_l F
+GLIBC_2.32 __strncasecmp_l F
+GLIBC_2.32 __strncat_chk F
+GLIBC_2.32 __strncpy_chk F
+GLIBC_2.32 __strndup F
+GLIBC_2.32 __strsep_g F
+GLIBC_2.32 __strtod_internal F
+GLIBC_2.32 __strtod_l F
+GLIBC_2.32 __strtof_internal F
+GLIBC_2.32 __strtof_l F
+GLIBC_2.32 __strtok_r F
+GLIBC_2.32 __strtol_internal F
+GLIBC_2.32 __strtol_l F
+GLIBC_2.32 __strtold_internal F
+GLIBC_2.32 __strtold_l F
+GLIBC_2.32 __strtoll_internal F
+GLIBC_2.32 __strtoll_l F
+GLIBC_2.32 __strtoul_internal F
+GLIBC_2.32 __strtoul_l F
+GLIBC_2.32 __strtoull_internal F
+GLIBC_2.32 __strtoull_l F
+GLIBC_2.32 __strverscmp F
+GLIBC_2.32 __strxfrm_l F
+GLIBC_2.32 __swprintf_chk F
+GLIBC_2.32 __syscall_error F
+GLIBC_2.32 __sysconf F
+GLIBC_2.32 __syslog_chk F
+GLIBC_2.32 __sysv_signal F
+GLIBC_2.32 __timezone D 0x4
+GLIBC_2.32 __toascii_l F
+GLIBC_2.32 __tolower_l F
+GLIBC_2.32 __toupper_l F
+GLIBC_2.32 __towctrans F
+GLIBC_2.32 __towctrans_l F
+GLIBC_2.32 __towlower_l F
+GLIBC_2.32 __towupper_l F
+GLIBC_2.32 __ttyname_r_chk F
+GLIBC_2.32 __tzname D 0x8
+GLIBC_2.32 __uflow F
+GLIBC_2.32 __underflow F
+GLIBC_2.32 __uselocale F
+GLIBC_2.32 __vasprintf_chk F
+GLIBC_2.32 __vdprintf_chk F
+GLIBC_2.32 __vfork F
+GLIBC_2.32 __vfprintf_chk F
+GLIBC_2.32 __vfscanf F
+GLIBC_2.32 __vfwprintf_chk F
+GLIBC_2.32 __vprintf_chk F
+GLIBC_2.32 __vsnprintf F
+GLIBC_2.32 __vsnprintf_chk F
+GLIBC_2.32 __vsprintf_chk F
+GLIBC_2.32 __vsscanf F
+GLIBC_2.32 __vswprintf_chk F
+GLIBC_2.32 __vsyslog_chk F
+GLIBC_2.32 __vwprintf_chk F
+GLIBC_2.32 __wait F
+GLIBC_2.32 __waitpid F
+GLIBC_2.32 __wcpcpy_chk F
+GLIBC_2.32 __wcpncpy_chk F
+GLIBC_2.32 __wcrtomb_chk F
+GLIBC_2.32 __wcscasecmp_l F
+GLIBC_2.32 __wcscat_chk F
+GLIBC_2.32 __wcscoll_l F
+GLIBC_2.32 __wcscpy_chk F
+GLIBC_2.32 __wcsftime_l F
+GLIBC_2.32 __wcsncasecmp_l F
+GLIBC_2.32 __wcsncat_chk F
+GLIBC_2.32 __wcsncpy_chk F
+GLIBC_2.32 __wcsnrtombs_chk F
+GLIBC_2.32 __wcsrtombs_chk F
+GLIBC_2.32 __wcstod_internal F
+GLIBC_2.32 __wcstod_l F
+GLIBC_2.32 __wcstof_internal F
+GLIBC_2.32 __wcstof_l F
+GLIBC_2.32 __wcstol_internal F
+GLIBC_2.32 __wcstol_l F
+GLIBC_2.32 __wcstold_internal F
+GLIBC_2.32 __wcstold_l F
+GLIBC_2.32 __wcstoll_internal F
+GLIBC_2.32 __wcstoll_l F
+GLIBC_2.32 __wcstombs_chk F
+GLIBC_2.32 __wcstoul_internal F
+GLIBC_2.32 __wcstoul_l F
+GLIBC_2.32 __wcstoull_internal F
+GLIBC_2.32 __wcstoull_l F
+GLIBC_2.32 __wcsxfrm_l F
+GLIBC_2.32 __wctomb_chk F
+GLIBC_2.32 __wctrans_l F
+GLIBC_2.32 __wctype_l F
+GLIBC_2.32 __wmemcpy_chk F
+GLIBC_2.32 __wmemmove_chk F
+GLIBC_2.32 __wmempcpy_chk F
+GLIBC_2.32 __wmemset_chk F
+GLIBC_2.32 __woverflow F
+GLIBC_2.32 __wprintf_chk F
+GLIBC_2.32 __write F
+GLIBC_2.32 __wuflow F
+GLIBC_2.32 __wunderflow F
+GLIBC_2.32 __xmknod F
+GLIBC_2.32 __xmknodat F
+GLIBC_2.32 __xpg_basename F
+GLIBC_2.32 __xpg_sigpause F
+GLIBC_2.32 __xpg_strerror_r F
+GLIBC_2.32 __xstat F
+GLIBC_2.32 __xstat64 F
+GLIBC_2.32 _authenticate F
+GLIBC_2.32 _dl_mcount_wrapper F
+GLIBC_2.32 _dl_mcount_wrapper_check F
+GLIBC_2.32 _environ D 0x4
+GLIBC_2.32 _exit F
+GLIBC_2.32 _flush_cache F
+GLIBC_2.32 _flushlbf F
+GLIBC_2.32 _libc_intl_domainname D 0x5
+GLIBC_2.32 _longjmp F
+GLIBC_2.32 _mcleanup F
+GLIBC_2.32 _mcount F
+GLIBC_2.32 _nl_default_dirname D 0x12
+GLIBC_2.32 _nl_domain_bindings D 0x4
+GLIBC_2.32 _nl_msg_cat_cntr D 0x4
+GLIBC_2.32 _null_auth D 0xc
+GLIBC_2.32 _obstack_allocated_p F
+GLIBC_2.32 _obstack_begin F
+GLIBC_2.32 _obstack_begin_1 F
+GLIBC_2.32 _obstack_free F
+GLIBC_2.32 _obstack_memory_used F
+GLIBC_2.32 _obstack_newchunk F
+GLIBC_2.32 _res D 0x200
+GLIBC_2.32 _res_hconf D 0x30
+GLIBC_2.32 _rpc_dtablesize F
+GLIBC_2.32 _seterr_reply F
+GLIBC_2.32 _setjmp F
+GLIBC_2.32 _sys_errlist D 0x21c
+GLIBC_2.32 _sys_nerr D 0x4
+GLIBC_2.32 _sys_siglist D 0x104
+GLIBC_2.32 _tolower F
+GLIBC_2.32 _toupper F
+GLIBC_2.32 a64l F
+GLIBC_2.32 abort F
+GLIBC_2.32 abs F
+GLIBC_2.32 accept F
+GLIBC_2.32 accept4 F
+GLIBC_2.32 access F
+GLIBC_2.32 acct F
+GLIBC_2.32 addmntent F
+GLIBC_2.32 addseverity F
+GLIBC_2.32 adjtime F
+GLIBC_2.32 adjtimex F
+GLIBC_2.32 alarm F
+GLIBC_2.32 aligned_alloc F
+GLIBC_2.32 alphasort F
+GLIBC_2.32 alphasort64 F
+GLIBC_2.32 argp_err_exit_status D 0x4
+GLIBC_2.32 argp_error F
+GLIBC_2.32 argp_failure F
+GLIBC_2.32 argp_help F
+GLIBC_2.32 argp_parse F
+GLIBC_2.32 argp_program_bug_address D 0x4
+GLIBC_2.32 argp_program_version D 0x4
+GLIBC_2.32 argp_program_version_hook D 0x4
+GLIBC_2.32 argp_state_help F
+GLIBC_2.32 argp_usage F
+GLIBC_2.32 argz_add F
+GLIBC_2.32 argz_add_sep F
+GLIBC_2.32 argz_append F
+GLIBC_2.32 argz_count F
+GLIBC_2.32 argz_create F
+GLIBC_2.32 argz_create_sep F
+GLIBC_2.32 argz_delete F
+GLIBC_2.32 argz_extract F
+GLIBC_2.32 argz_insert F
+GLIBC_2.32 argz_next F
+GLIBC_2.32 argz_replace F
+GLIBC_2.32 argz_stringify F
+GLIBC_2.32 asctime F
+GLIBC_2.32 asctime_r F
+GLIBC_2.32 asprintf F
+GLIBC_2.32 atof F
+GLIBC_2.32 atoi F
+GLIBC_2.32 atol F
+GLIBC_2.32 atoll F
+GLIBC_2.32 authdes_create F
+GLIBC_2.32 authdes_getucred F
+GLIBC_2.32 authdes_pk_create F
+GLIBC_2.32 authnone_create F
+GLIBC_2.32 authunix_create F
+GLIBC_2.32 authunix_create_default F
+GLIBC_2.32 backtrace F
+GLIBC_2.32 backtrace_symbols F
+GLIBC_2.32 backtrace_symbols_fd F
+GLIBC_2.32 basename F
+GLIBC_2.32 bcmp F
+GLIBC_2.32 bcopy F
+GLIBC_2.32 bind F
+GLIBC_2.32 bind_textdomain_codeset F
+GLIBC_2.32 bindresvport F
+GLIBC_2.32 bindtextdomain F
+GLIBC_2.32 brk F
+GLIBC_2.32 bsd_signal F
+GLIBC_2.32 bsearch F
+GLIBC_2.32 btowc F
+GLIBC_2.32 bzero F
+GLIBC_2.32 c16rtomb F
+GLIBC_2.32 c32rtomb F
+GLIBC_2.32 cacheflush F
+GLIBC_2.32 calloc F
+GLIBC_2.32 callrpc F
+GLIBC_2.32 canonicalize_file_name F
+GLIBC_2.32 capget F
+GLIBC_2.32 capset F
+GLIBC_2.32 catclose F
+GLIBC_2.32 catgets F
+GLIBC_2.32 catopen F
+GLIBC_2.32 cbc_crypt F
+GLIBC_2.32 cfgetispeed F
+GLIBC_2.32 cfgetospeed F
+GLIBC_2.32 cfmakeraw F
+GLIBC_2.32 cfsetispeed F
+GLIBC_2.32 cfsetospeed F
+GLIBC_2.32 cfsetspeed F
+GLIBC_2.32 chdir F
+GLIBC_2.32 chflags F
+GLIBC_2.32 chmod F
+GLIBC_2.32 chown F
+GLIBC_2.32 chroot F
+GLIBC_2.32 clearenv F
+GLIBC_2.32 clearerr F
+GLIBC_2.32 clearerr_unlocked F
+GLIBC_2.32 clnt_broadcast F
+GLIBC_2.32 clnt_create F
+GLIBC_2.32 clnt_pcreateerror F
+GLIBC_2.32 clnt_perrno F
+GLIBC_2.32 clnt_perror F
+GLIBC_2.32 clnt_spcreateerror F
+GLIBC_2.32 clnt_sperrno F
+GLIBC_2.32 clnt_sperror F
+GLIBC_2.32 clntraw_create F
+GLIBC_2.32 clnttcp_create F
+GLIBC_2.32 clntudp_bufcreate F
+GLIBC_2.32 clntudp_create F
+GLIBC_2.32 clntunix_create F
+GLIBC_2.32 clock F
+GLIBC_2.32 clock_adjtime F
+GLIBC_2.32 clock_getcpuclockid F
+GLIBC_2.32 clock_getres F
+GLIBC_2.32 clock_gettime F
+GLIBC_2.32 clock_nanosleep F
+GLIBC_2.32 clock_settime F
+GLIBC_2.32 clone F
+GLIBC_2.32 close F
+GLIBC_2.32 closedir F
+GLIBC_2.32 closelog F
+GLIBC_2.32 confstr F
+GLIBC_2.32 connect F
+GLIBC_2.32 copy_file_range F
+GLIBC_2.32 copysign F
+GLIBC_2.32 copysignf F
+GLIBC_2.32 copysignl F
+GLIBC_2.32 creat F
+GLIBC_2.32 creat64 F
+GLIBC_2.32 ctermid F
+GLIBC_2.32 ctime F
+GLIBC_2.32 ctime_r F
+GLIBC_2.32 cuserid F
+GLIBC_2.32 daemon F
+GLIBC_2.32 daylight D 0x4
+GLIBC_2.32 dcgettext F
+GLIBC_2.32 dcngettext F
+GLIBC_2.32 delete_module F
+GLIBC_2.32 des_setparity F
+GLIBC_2.32 dgettext F
+GLIBC_2.32 difftime F
+GLIBC_2.32 dirfd F
+GLIBC_2.32 dirname F
+GLIBC_2.32 div F
+GLIBC_2.32 dl_iterate_phdr F
+GLIBC_2.32 dngettext F
+GLIBC_2.32 dprintf F
+GLIBC_2.32 drand48 F
+GLIBC_2.32 drand48_r F
+GLIBC_2.32 dup F
+GLIBC_2.32 dup2 F
+GLIBC_2.32 dup3 F
+GLIBC_2.32 duplocale F
+GLIBC_2.32 dysize F
+GLIBC_2.32 eaccess F
+GLIBC_2.32 ecb_crypt F
+GLIBC_2.32 ecvt F
+GLIBC_2.32 ecvt_r F
+GLIBC_2.32 endaliasent F
+GLIBC_2.32 endfsent F
+GLIBC_2.32 endgrent F
+GLIBC_2.32 endhostent F
+GLIBC_2.32 endmntent F
+GLIBC_2.32 endnetent F
+GLIBC_2.32 endnetgrent F
+GLIBC_2.32 endprotoent F
+GLIBC_2.32 endpwent F
+GLIBC_2.32 endrpcent F
+GLIBC_2.32 endservent F
+GLIBC_2.32 endsgent F
+GLIBC_2.32 endspent F
+GLIBC_2.32 endttyent F
+GLIBC_2.32 endusershell F
+GLIBC_2.32 endutent F
+GLIBC_2.32 endutxent F
+GLIBC_2.32 environ D 0x4
+GLIBC_2.32 envz_add F
+GLIBC_2.32 envz_entry F
+GLIBC_2.32 envz_get F
+GLIBC_2.32 envz_merge F
+GLIBC_2.32 envz_remove F
+GLIBC_2.32 envz_strip F
+GLIBC_2.32 epoll_create F
+GLIBC_2.32 epoll_create1 F
+GLIBC_2.32 epoll_ctl F
+GLIBC_2.32 epoll_pwait F
+GLIBC_2.32 epoll_wait F
+GLIBC_2.32 erand48 F
+GLIBC_2.32 erand48_r F
+GLIBC_2.32 err F
+GLIBC_2.32 error F
+GLIBC_2.32 error_at_line F
+GLIBC_2.32 error_message_count D 0x4
+GLIBC_2.32 error_one_per_line D 0x4
+GLIBC_2.32 error_print_progname D 0x4
+GLIBC_2.32 errx F
+GLIBC_2.32 ether_aton F
+GLIBC_2.32 ether_aton_r F
+GLIBC_2.32 ether_hostton F
+GLIBC_2.32 ether_line F
+GLIBC_2.32 ether_ntoa F
+GLIBC_2.32 ether_ntoa_r F
+GLIBC_2.32 ether_ntohost F
+GLIBC_2.32 euidaccess F
+GLIBC_2.32 eventfd F
+GLIBC_2.32 eventfd_read F
+GLIBC_2.32 eventfd_write F
+GLIBC_2.32 execl F
+GLIBC_2.32 execle F
+GLIBC_2.32 execlp F
+GLIBC_2.32 execv F
+GLIBC_2.32 execve F
+GLIBC_2.32 execvp F
+GLIBC_2.32 execvpe F
+GLIBC_2.32 exit F
+GLIBC_2.32 explicit_bzero F
+GLIBC_2.32 faccessat F
+GLIBC_2.32 fallocate F
+GLIBC_2.32 fallocate64 F
+GLIBC_2.32 fanotify_init F
+GLIBC_2.32 fanotify_mark F
+GLIBC_2.32 fchdir F
+GLIBC_2.32 fchflags F
+GLIBC_2.32 fchmod F
+GLIBC_2.32 fchmodat F
+GLIBC_2.32 fchown F
+GLIBC_2.32 fchownat F
+GLIBC_2.32 fclose F
+GLIBC_2.32 fcloseall F
+GLIBC_2.32 fcntl F
+GLIBC_2.32 fcntl64 F
+GLIBC_2.32 fcvt F
+GLIBC_2.32 fcvt_r F
+GLIBC_2.32 fdatasync F
+GLIBC_2.32 fdopen F
+GLIBC_2.32 fdopendir F
+GLIBC_2.32 feof F
+GLIBC_2.32 feof_unlocked F
+GLIBC_2.32 ferror F
+GLIBC_2.32 ferror_unlocked F
+GLIBC_2.32 fexecve F
+GLIBC_2.32 fflush F
+GLIBC_2.32 fflush_unlocked F
+GLIBC_2.32 ffs F
+GLIBC_2.32 ffsl F
+GLIBC_2.32 ffsll F
+GLIBC_2.32 fgetc F
+GLIBC_2.32 fgetc_unlocked F
+GLIBC_2.32 fgetgrent F
+GLIBC_2.32 fgetgrent_r F
+GLIBC_2.32 fgetpos F
+GLIBC_2.32 fgetpos64 F
+GLIBC_2.32 fgetpwent F
+GLIBC_2.32 fgetpwent_r F
+GLIBC_2.32 fgets F
+GLIBC_2.32 fgets_unlocked F
+GLIBC_2.32 fgetsgent F
+GLIBC_2.32 fgetsgent_r F
+GLIBC_2.32 fgetspent F
+GLIBC_2.32 fgetspent_r F
+GLIBC_2.32 fgetwc F
+GLIBC_2.32 fgetwc_unlocked F
+GLIBC_2.32 fgetws F
+GLIBC_2.32 fgetws_unlocked F
+GLIBC_2.32 fgetxattr F
+GLIBC_2.32 fileno F
+GLIBC_2.32 fileno_unlocked F
+GLIBC_2.32 finite F
+GLIBC_2.32 finitef F
+GLIBC_2.32 finitel F
+GLIBC_2.32 flistxattr F
+GLIBC_2.32 flock F
+GLIBC_2.32 flockfile F
+GLIBC_2.32 fmemopen F
+GLIBC_2.32 fmtmsg F
+GLIBC_2.32 fnmatch F
+GLIBC_2.32 fopen F
+GLIBC_2.32 fopen64 F
+GLIBC_2.32 fopencookie F
+GLIBC_2.32 fork F
+GLIBC_2.32 fpathconf F
+GLIBC_2.32 fprintf F
+GLIBC_2.32 fputc F
+GLIBC_2.32 fputc_unlocked F
+GLIBC_2.32 fputs F
+GLIBC_2.32 fputs_unlocked F
+GLIBC_2.32 fputwc F
+GLIBC_2.32 fputwc_unlocked F
+GLIBC_2.32 fputws F
+GLIBC_2.32 fputws_unlocked F
+GLIBC_2.32 fread F
+GLIBC_2.32 fread_unlocked F
+GLIBC_2.32 free F
+GLIBC_2.32 freeaddrinfo F
+GLIBC_2.32 freeifaddrs F
+GLIBC_2.32 freelocale F
+GLIBC_2.32 fremovexattr F
+GLIBC_2.32 freopen F
+GLIBC_2.32 freopen64 F
+GLIBC_2.32 frexp F
+GLIBC_2.32 frexpf F
+GLIBC_2.32 frexpl F
+GLIBC_2.32 fscanf F
+GLIBC_2.32 fseek F
+GLIBC_2.32 fseeko F
+GLIBC_2.32 fseeko64 F
+GLIBC_2.32 fsetpos F
+GLIBC_2.32 fsetpos64 F
+GLIBC_2.32 fsetxattr F
+GLIBC_2.32 fstatfs F
+GLIBC_2.32 fstatfs64 F
+GLIBC_2.32 fstatvfs F
+GLIBC_2.32 fstatvfs64 F
+GLIBC_2.32 fsync F
+GLIBC_2.32 ftell F
+GLIBC_2.32 ftello F
+GLIBC_2.32 ftello64 F
+GLIBC_2.32 ftime F
+GLIBC_2.32 ftok F
+GLIBC_2.32 ftruncate F
+GLIBC_2.32 ftruncate64 F
+GLIBC_2.32 ftrylockfile F
+GLIBC_2.32 fts64_children F
+GLIBC_2.32 fts64_close F
+GLIBC_2.32 fts64_open F
+GLIBC_2.32 fts64_read F
+GLIBC_2.32 fts64_set F
+GLIBC_2.32 fts_children F
+GLIBC_2.32 fts_close F
+GLIBC_2.32 fts_open F
+GLIBC_2.32 fts_read F
+GLIBC_2.32 fts_set F
+GLIBC_2.32 ftw F
+GLIBC_2.32 ftw64 F
+GLIBC_2.32 funlockfile F
+GLIBC_2.32 futimens F
+GLIBC_2.32 futimes F
+GLIBC_2.32 futimesat F
+GLIBC_2.32 fwide F
+GLIBC_2.32 fwprintf F
+GLIBC_2.32 fwrite F
+GLIBC_2.32 fwrite_unlocked F
+GLIBC_2.32 fwscanf F
+GLIBC_2.32 gai_strerror F
+GLIBC_2.32 gcvt F
+GLIBC_2.32 get_avphys_pages F
+GLIBC_2.32 get_current_dir_name F
+GLIBC_2.32 get_myaddress F
+GLIBC_2.32 get_nprocs F
+GLIBC_2.32 get_nprocs_conf F
+GLIBC_2.32 get_phys_pages F
+GLIBC_2.32 getaddrinfo F
+GLIBC_2.32 getaliasbyname F
+GLIBC_2.32 getaliasbyname_r F
+GLIBC_2.32 getaliasent F
+GLIBC_2.32 getaliasent_r F
+GLIBC_2.32 getauxval F
+GLIBC_2.32 getc F
+GLIBC_2.32 getc_unlocked F
+GLIBC_2.32 getchar F
+GLIBC_2.32 getchar_unlocked F
+GLIBC_2.32 getcontext F
+GLIBC_2.32 getcpu F
+GLIBC_2.32 getcwd F
+GLIBC_2.32 getdate F
+GLIBC_2.32 getdate_err D 0x4
+GLIBC_2.32 getdate_r F
+GLIBC_2.32 getdelim F
+GLIBC_2.32 getdents64 F
+GLIBC_2.32 getdirentries F
+GLIBC_2.32 getdirentries64 F
+GLIBC_2.32 getdomainname F
+GLIBC_2.32 getdtablesize F
+GLIBC_2.32 getegid F
+GLIBC_2.32 getentropy F
+GLIBC_2.32 getenv F
+GLIBC_2.32 geteuid F
+GLIBC_2.32 getfsent F
+GLIBC_2.32 getfsfile F
+GLIBC_2.32 getfsspec F
+GLIBC_2.32 getgid F
+GLIBC_2.32 getgrent F
+GLIBC_2.32 getgrent_r F
+GLIBC_2.32 getgrgid F
+GLIBC_2.32 getgrgid_r F
+GLIBC_2.32 getgrnam F
+GLIBC_2.32 getgrnam_r F
+GLIBC_2.32 getgrouplist F
+GLIBC_2.32 getgroups F
+GLIBC_2.32 gethostbyaddr F
+GLIBC_2.32 gethostbyaddr_r F
+GLIBC_2.32 gethostbyname F
+GLIBC_2.32 gethostbyname2 F
+GLIBC_2.32 gethostbyname2_r F
+GLIBC_2.32 gethostbyname_r F
+GLIBC_2.32 gethostent F
+GLIBC_2.32 gethostent_r F
+GLIBC_2.32 gethostid F
+GLIBC_2.32 gethostname F
+GLIBC_2.32 getifaddrs F
+GLIBC_2.32 getipv4sourcefilter F
+GLIBC_2.32 getitimer F
+GLIBC_2.32 getline F
+GLIBC_2.32 getloadavg F
+GLIBC_2.32 getlogin F
+GLIBC_2.32 getlogin_r F
+GLIBC_2.32 getmntent F
+GLIBC_2.32 getmntent_r F
+GLIBC_2.32 getnameinfo F
+GLIBC_2.32 getnetbyaddr F
+GLIBC_2.32 getnetbyaddr_r F
+GLIBC_2.32 getnetbyname F
+GLIBC_2.32 getnetbyname_r F
+GLIBC_2.32 getnetent F
+GLIBC_2.32 getnetent_r F
+GLIBC_2.32 getnetgrent F
+GLIBC_2.32 getnetgrent_r F
+GLIBC_2.32 getnetname F
+GLIBC_2.32 getopt F
+GLIBC_2.32 getopt_long F
+GLIBC_2.32 getopt_long_only F
+GLIBC_2.32 getpagesize F
+GLIBC_2.32 getpass F
+GLIBC_2.32 getpeername F
+GLIBC_2.32 getpgid F
+GLIBC_2.32 getpgrp F
+GLIBC_2.32 getpid F
+GLIBC_2.32 getppid F
+GLIBC_2.32 getpriority F
+GLIBC_2.32 getprotobyname F
+GLIBC_2.32 getprotobyname_r F
+GLIBC_2.32 getprotobynumber F
+GLIBC_2.32 getprotobynumber_r F
+GLIBC_2.32 getprotoent F
+GLIBC_2.32 getprotoent_r F
+GLIBC_2.32 getpt F
+GLIBC_2.32 getpublickey F
+GLIBC_2.32 getpw F
+GLIBC_2.32 getpwent F
+GLIBC_2.32 getpwent_r F
+GLIBC_2.32 getpwnam F
+GLIBC_2.32 getpwnam_r F
+GLIBC_2.32 getpwuid F
+GLIBC_2.32 getpwuid_r F
+GLIBC_2.32 getrandom F
+GLIBC_2.32 getresgid F
+GLIBC_2.32 getresuid F
+GLIBC_2.32 getrlimit F
+GLIBC_2.32 getrlimit64 F
+GLIBC_2.32 getrpcbyname F
+GLIBC_2.32 getrpcbyname_r F
+GLIBC_2.32 getrpcbynumber F
+GLIBC_2.32 getrpcbynumber_r F
+GLIBC_2.32 getrpcent F
+GLIBC_2.32 getrpcent_r F
+GLIBC_2.32 getrpcport F
+GLIBC_2.32 getrusage F
+GLIBC_2.32 gets F
+GLIBC_2.32 getsecretkey F
+GLIBC_2.32 getservbyname F
+GLIBC_2.32 getservbyname_r F
+GLIBC_2.32 getservbyport F
+GLIBC_2.32 getservbyport_r F
+GLIBC_2.32 getservent F
+GLIBC_2.32 getservent_r F
+GLIBC_2.32 getsgent F
+GLIBC_2.32 getsgent_r F
+GLIBC_2.32 getsgnam F
+GLIBC_2.32 getsgnam_r F
+GLIBC_2.32 getsid F
+GLIBC_2.32 getsockname F
+GLIBC_2.32 getsockopt F
+GLIBC_2.32 getsourcefilter F
+GLIBC_2.32 getspent F
+GLIBC_2.32 getspent_r F
+GLIBC_2.32 getspnam F
+GLIBC_2.32 getspnam_r F
+GLIBC_2.32 getsubopt F
+GLIBC_2.32 gettext F
+GLIBC_2.32 gettid F
+GLIBC_2.32 gettimeofday F
+GLIBC_2.32 getttyent F
+GLIBC_2.32 getttynam F
+GLIBC_2.32 getuid F
+GLIBC_2.32 getusershell F
+GLIBC_2.32 getutent F
+GLIBC_2.32 getutent_r F
+GLIBC_2.32 getutid F
+GLIBC_2.32 getutid_r F
+GLIBC_2.32 getutline F
+GLIBC_2.32 getutline_r F
+GLIBC_2.32 getutmp F
+GLIBC_2.32 getutmpx F
+GLIBC_2.32 getutxent F
+GLIBC_2.32 getutxid F
+GLIBC_2.32 getutxline F
+GLIBC_2.32 getw F
+GLIBC_2.32 getwc F
+GLIBC_2.32 getwc_unlocked F
+GLIBC_2.32 getwchar F
+GLIBC_2.32 getwchar_unlocked F
+GLIBC_2.32 getwd F
+GLIBC_2.32 getxattr F
+GLIBC_2.32 glob F
+GLIBC_2.32 glob64 F
+GLIBC_2.32 glob_pattern_p F
+GLIBC_2.32 globfree F
+GLIBC_2.32 globfree64 F
+GLIBC_2.32 gmtime F
+GLIBC_2.32 gmtime_r F
+GLIBC_2.32 gnu_dev_major F
+GLIBC_2.32 gnu_dev_makedev F
+GLIBC_2.32 gnu_dev_minor F
+GLIBC_2.32 gnu_get_libc_release F
+GLIBC_2.32 gnu_get_libc_version F
+GLIBC_2.32 grantpt F
+GLIBC_2.32 group_member F
+GLIBC_2.32 gsignal F
+GLIBC_2.32 gtty F
+GLIBC_2.32 h_errlist D 0x14
+GLIBC_2.32 h_nerr D 0x4
+GLIBC_2.32 hasmntopt F
+GLIBC_2.32 hcreate F
+GLIBC_2.32 hcreate_r F
+GLIBC_2.32 hdestroy F
+GLIBC_2.32 hdestroy_r F
+GLIBC_2.32 herror F
+GLIBC_2.32 host2netname F
+GLIBC_2.32 hsearch F
+GLIBC_2.32 hsearch_r F
+GLIBC_2.32 hstrerror F
+GLIBC_2.32 htonl F
+GLIBC_2.32 htons F
+GLIBC_2.32 iconv F
+GLIBC_2.32 iconv_close F
+GLIBC_2.32 iconv_open F
+GLIBC_2.32 if_freenameindex F
+GLIBC_2.32 if_indextoname F
+GLIBC_2.32 if_nameindex F
+GLIBC_2.32 if_nametoindex F
+GLIBC_2.32 imaxabs F
+GLIBC_2.32 imaxdiv F
+GLIBC_2.32 in6addr_any D 0x10
+GLIBC_2.32 in6addr_loopback D 0x10
+GLIBC_2.32 index F
+GLIBC_2.32 inet6_opt_append F
+GLIBC_2.32 inet6_opt_find F
+GLIBC_2.32 inet6_opt_finish F
+GLIBC_2.32 inet6_opt_get_val F
+GLIBC_2.32 inet6_opt_init F
+GLIBC_2.32 inet6_opt_next F
+GLIBC_2.32 inet6_opt_set_val F
+GLIBC_2.32 inet6_option_alloc F
+GLIBC_2.32 inet6_option_append F
+GLIBC_2.32 inet6_option_find F
+GLIBC_2.32 inet6_option_init F
+GLIBC_2.32 inet6_option_next F
+GLIBC_2.32 inet6_option_space F
+GLIBC_2.32 inet6_rth_add F
+GLIBC_2.32 inet6_rth_getaddr F
+GLIBC_2.32 inet6_rth_init F
+GLIBC_2.32 inet6_rth_reverse F
+GLIBC_2.32 inet6_rth_segments F
+GLIBC_2.32 inet6_rth_space F
+GLIBC_2.32 inet_addr F
+GLIBC_2.32 inet_aton F
+GLIBC_2.32 inet_lnaof F
+GLIBC_2.32 inet_makeaddr F
+GLIBC_2.32 inet_netof F
+GLIBC_2.32 inet_network F
+GLIBC_2.32 inet_nsap_addr F
+GLIBC_2.32 inet_nsap_ntoa F
+GLIBC_2.32 inet_ntoa F
+GLIBC_2.32 inet_ntop F
+GLIBC_2.32 inet_pton F
+GLIBC_2.32 init_module F
+GLIBC_2.32 initgroups F
+GLIBC_2.32 initstate F
+GLIBC_2.32 initstate_r F
+GLIBC_2.32 innetgr F
+GLIBC_2.32 inotify_add_watch F
+GLIBC_2.32 inotify_init F
+GLIBC_2.32 inotify_init1 F
+GLIBC_2.32 inotify_rm_watch F
+GLIBC_2.32 insque F
+GLIBC_2.32 ioctl F
+GLIBC_2.32 iruserok F
+GLIBC_2.32 iruserok_af F
+GLIBC_2.32 isalnum F
+GLIBC_2.32 isalnum_l F
+GLIBC_2.32 isalpha F
+GLIBC_2.32 isalpha_l F
+GLIBC_2.32 isascii F
+GLIBC_2.32 isatty F
+GLIBC_2.32 isblank F
+GLIBC_2.32 isblank_l F
+GLIBC_2.32 iscntrl F
+GLIBC_2.32 iscntrl_l F
+GLIBC_2.32 isctype F
+GLIBC_2.32 isdigit F
+GLIBC_2.32 isdigit_l F
+GLIBC_2.32 isfdtype F
+GLIBC_2.32 isgraph F
+GLIBC_2.32 isgraph_l F
+GLIBC_2.32 isinf F
+GLIBC_2.32 isinff F
+GLIBC_2.32 isinfl F
+GLIBC_2.32 islower F
+GLIBC_2.32 islower_l F
+GLIBC_2.32 isnan F
+GLIBC_2.32 isnanf F
+GLIBC_2.32 isnanl F
+GLIBC_2.32 isprint F
+GLIBC_2.32 isprint_l F
+GLIBC_2.32 ispunct F
+GLIBC_2.32 ispunct_l F
+GLIBC_2.32 isspace F
+GLIBC_2.32 isspace_l F
+GLIBC_2.32 isupper F
+GLIBC_2.32 isupper_l F
+GLIBC_2.32 iswalnum F
+GLIBC_2.32 iswalnum_l F
+GLIBC_2.32 iswalpha F
+GLIBC_2.32 iswalpha_l F
+GLIBC_2.32 iswblank F
+GLIBC_2.32 iswblank_l F
+GLIBC_2.32 iswcntrl F
+GLIBC_2.32 iswcntrl_l F
+GLIBC_2.32 iswctype F
+GLIBC_2.32 iswctype_l F
+GLIBC_2.32 iswdigit F
+GLIBC_2.32 iswdigit_l F
+GLIBC_2.32 iswgraph F
+GLIBC_2.32 iswgraph_l F
+GLIBC_2.32 iswlower F
+GLIBC_2.32 iswlower_l F
+GLIBC_2.32 iswprint F
+GLIBC_2.32 iswprint_l F
+GLIBC_2.32 iswpunct F
+GLIBC_2.32 iswpunct_l F
+GLIBC_2.32 iswspace F
+GLIBC_2.32 iswspace_l F
+GLIBC_2.32 iswupper F
+GLIBC_2.32 iswupper_l F
+GLIBC_2.32 iswxdigit F
+GLIBC_2.32 iswxdigit_l F
+GLIBC_2.32 isxdigit F
+GLIBC_2.32 isxdigit_l F
+GLIBC_2.32 jrand48 F
+GLIBC_2.32 jrand48_r F
+GLIBC_2.32 key_decryptsession F
+GLIBC_2.32 key_decryptsession_pk F
+GLIBC_2.32 key_encryptsession F
+GLIBC_2.32 key_encryptsession_pk F
+GLIBC_2.32 key_gendes F
+GLIBC_2.32 key_get_conv F
+GLIBC_2.32 key_secretkey_is_set F
+GLIBC_2.32 key_setnet F
+GLIBC_2.32 key_setsecret F
+GLIBC_2.32 kill F
+GLIBC_2.32 killpg F
+GLIBC_2.32 klogctl F
+GLIBC_2.32 l64a F
+GLIBC_2.32 labs F
+GLIBC_2.32 lchmod F
+GLIBC_2.32 lchown F
+GLIBC_2.32 lckpwdf F
+GLIBC_2.32 lcong48 F
+GLIBC_2.32 lcong48_r F
+GLIBC_2.32 ldexp F
+GLIBC_2.32 ldexpf F
+GLIBC_2.32 ldexpl F
+GLIBC_2.32 ldiv F
+GLIBC_2.32 lfind F
+GLIBC_2.32 lgetxattr F
+GLIBC_2.32 link F
+GLIBC_2.32 linkat F
+GLIBC_2.32 listen F
+GLIBC_2.32 listxattr F
+GLIBC_2.32 llabs F
+GLIBC_2.32 lldiv F
+GLIBC_2.32 llistxattr F
+GLIBC_2.32 localeconv F
+GLIBC_2.32 localtime F
+GLIBC_2.32 localtime_r F
+GLIBC_2.32 lockf F
+GLIBC_2.32 lockf64 F
+GLIBC_2.32 longjmp F
+GLIBC_2.32 lrand48 F
+GLIBC_2.32 lrand48_r F
+GLIBC_2.32 lremovexattr F
+GLIBC_2.32 lsearch F
+GLIBC_2.32 lseek F
+GLIBC_2.32 lseek64 F
+GLIBC_2.32 lsetxattr F
+GLIBC_2.32 lutimes F
+GLIBC_2.32 madvise F
+GLIBC_2.32 makecontext F
+GLIBC_2.32 mallinfo F
+GLIBC_2.32 malloc F
+GLIBC_2.32 malloc_info F
+GLIBC_2.32 malloc_stats F
+GLIBC_2.32 malloc_trim F
+GLIBC_2.32 malloc_usable_size F
+GLIBC_2.32 mallopt F
+GLIBC_2.32 mallwatch D 0x4
+GLIBC_2.32 mblen F
+GLIBC_2.32 mbrlen F
+GLIBC_2.32 mbrtoc16 F
+GLIBC_2.32 mbrtoc32 F
+GLIBC_2.32 mbrtowc F
+GLIBC_2.32 mbsinit F
+GLIBC_2.32 mbsnrtowcs F
+GLIBC_2.32 mbsrtowcs F
+GLIBC_2.32 mbstowcs F
+GLIBC_2.32 mbtowc F
+GLIBC_2.32 mcheck F
+GLIBC_2.32 mcheck_check_all F
+GLIBC_2.32 mcheck_pedantic F
+GLIBC_2.32 memalign F
+GLIBC_2.32 memccpy F
+GLIBC_2.32 memchr F
+GLIBC_2.32 memcmp F
+GLIBC_2.32 memcpy F
+GLIBC_2.32 memfd_create F
+GLIBC_2.32 memfrob F
+GLIBC_2.32 memmem F
+GLIBC_2.32 memmove F
+GLIBC_2.32 mempcpy F
+GLIBC_2.32 memrchr F
+GLIBC_2.32 memset F
+GLIBC_2.32 mincore F
+GLIBC_2.32 mkdir F
+GLIBC_2.32 mkdirat F
+GLIBC_2.32 mkdtemp F
+GLIBC_2.32 mkfifo F
+GLIBC_2.32 mkfifoat F
+GLIBC_2.32 mkostemp F
+GLIBC_2.32 mkostemp64 F
+GLIBC_2.32 mkostemps F
+GLIBC_2.32 mkostemps64 F
+GLIBC_2.32 mkstemp F
+GLIBC_2.32 mkstemp64 F
+GLIBC_2.32 mkstemps F
+GLIBC_2.32 mkstemps64 F
+GLIBC_2.32 mktemp F
+GLIBC_2.32 mktime F
+GLIBC_2.32 mlock F
+GLIBC_2.32 mlock2 F
+GLIBC_2.32 mlockall F
+GLIBC_2.32 mmap F
+GLIBC_2.32 mmap64 F
+GLIBC_2.32 modf F
+GLIBC_2.32 modff F
+GLIBC_2.32 modfl F
+GLIBC_2.32 moncontrol F
+GLIBC_2.32 monstartup F
+GLIBC_2.32 mount F
+GLIBC_2.32 mprobe F
+GLIBC_2.32 mprotect F
+GLIBC_2.32 mrand48 F
+GLIBC_2.32 mrand48_r F
+GLIBC_2.32 mremap F
+GLIBC_2.32 msgctl F
+GLIBC_2.32 msgget F
+GLIBC_2.32 msgrcv F
+GLIBC_2.32 msgsnd F
+GLIBC_2.32 msync F
+GLIBC_2.32 mtrace F
+GLIBC_2.32 munlock F
+GLIBC_2.32 munlockall F
+GLIBC_2.32 munmap F
+GLIBC_2.32 muntrace F
+GLIBC_2.32 name_to_handle_at F
+GLIBC_2.32 nanosleep F
+GLIBC_2.32 netname2host F
+GLIBC_2.32 netname2user F
+GLIBC_2.32 newlocale F
+GLIBC_2.32 nftw F
+GLIBC_2.32 nftw64 F
+GLIBC_2.32 ngettext F
+GLIBC_2.32 nice F
+GLIBC_2.32 nl_langinfo F
+GLIBC_2.32 nl_langinfo_l F
+GLIBC_2.32 nrand48 F
+GLIBC_2.32 nrand48_r F
+GLIBC_2.32 ntohl F
+GLIBC_2.32 ntohs F
+GLIBC_2.32 ntp_adjtime F
+GLIBC_2.32 ntp_gettime F
+GLIBC_2.32 ntp_gettimex F
+GLIBC_2.32 obstack_alloc_failed_handler D 0x4
+GLIBC_2.32 obstack_exit_failure D 0x4
+GLIBC_2.32 obstack_free F
+GLIBC_2.32 obstack_printf F
+GLIBC_2.32 obstack_vprintf F
+GLIBC_2.32 on_exit F
+GLIBC_2.32 open F
+GLIBC_2.32 open64 F
+GLIBC_2.32 open_by_handle_at F
+GLIBC_2.32 open_memstream F
+GLIBC_2.32 open_wmemstream F
+GLIBC_2.32 openat F
+GLIBC_2.32 openat64 F
+GLIBC_2.32 opendir F
+GLIBC_2.32 openlog F
+GLIBC_2.32 optarg D 0x4
+GLIBC_2.32 opterr D 0x4
+GLIBC_2.32 optind D 0x4
+GLIBC_2.32 optopt D 0x4
+GLIBC_2.32 parse_printf_format F
+GLIBC_2.32 passwd2des F
+GLIBC_2.32 pathconf F
+GLIBC_2.32 pause F
+GLIBC_2.32 pclose F
+GLIBC_2.32 perror F
+GLIBC_2.32 personality F
+GLIBC_2.32 pipe F
+GLIBC_2.32 pipe2 F
+GLIBC_2.32 pivot_root F
+GLIBC_2.32 pkey_alloc F
+GLIBC_2.32 pkey_free F
+GLIBC_2.32 pkey_get F
+GLIBC_2.32 pkey_mprotect F
+GLIBC_2.32 pkey_set F
+GLIBC_2.32 pmap_getmaps F
+GLIBC_2.32 pmap_getport F
+GLIBC_2.32 pmap_rmtcall F
+GLIBC_2.32 pmap_set F
+GLIBC_2.32 pmap_unset F
+GLIBC_2.32 poll F
+GLIBC_2.32 popen F
+GLIBC_2.32 posix_fadvise F
+GLIBC_2.32 posix_fadvise64 F
+GLIBC_2.32 posix_fallocate F
+GLIBC_2.32 posix_fallocate64 F
+GLIBC_2.32 posix_madvise F
+GLIBC_2.32 posix_memalign F
+GLIBC_2.32 posix_openpt F
+GLIBC_2.32 posix_spawn F
+GLIBC_2.32 posix_spawn_file_actions_addchdir_np F
+GLIBC_2.32 posix_spawn_file_actions_addclose F
+GLIBC_2.32 posix_spawn_file_actions_adddup2 F
+GLIBC_2.32 posix_spawn_file_actions_addfchdir_np F
+GLIBC_2.32 posix_spawn_file_actions_addopen F
+GLIBC_2.32 posix_spawn_file_actions_destroy F
+GLIBC_2.32 posix_spawn_file_actions_init F
+GLIBC_2.32 posix_spawnattr_destroy F
+GLIBC_2.32 posix_spawnattr_getflags F
+GLIBC_2.32 posix_spawnattr_getpgroup F
+GLIBC_2.32 posix_spawnattr_getschedparam F
+GLIBC_2.32 posix_spawnattr_getschedpolicy F
+GLIBC_2.32 posix_spawnattr_getsigdefault F
+GLIBC_2.32 posix_spawnattr_getsigmask F
+GLIBC_2.32 posix_spawnattr_init F
+GLIBC_2.32 posix_spawnattr_setflags F
+GLIBC_2.32 posix_spawnattr_setpgroup F
+GLIBC_2.32 posix_spawnattr_setschedparam F
+GLIBC_2.32 posix_spawnattr_setschedpolicy F
+GLIBC_2.32 posix_spawnattr_setsigdefault F
+GLIBC_2.32 posix_spawnattr_setsigmask F
+GLIBC_2.32 posix_spawnp F
+GLIBC_2.32 ppoll F
+GLIBC_2.32 prctl F
+GLIBC_2.32 pread F
+GLIBC_2.32 pread64 F
+GLIBC_2.32 preadv F
+GLIBC_2.32 preadv2 F
+GLIBC_2.32 preadv64 F
+GLIBC_2.32 preadv64v2 F
+GLIBC_2.32 printf F
+GLIBC_2.32 printf_size F
+GLIBC_2.32 printf_size_info F
+GLIBC_2.32 prlimit F
+GLIBC_2.32 prlimit64 F
+GLIBC_2.32 process_vm_readv F
+GLIBC_2.32 process_vm_writev F
+GLIBC_2.32 profil F
+GLIBC_2.32 program_invocation_name D 0x4
+GLIBC_2.32 program_invocation_short_name D 0x4
+GLIBC_2.32 pselect F
+GLIBC_2.32 psiginfo F
+GLIBC_2.32 psignal F
+GLIBC_2.32 pthread_attr_destroy F
+GLIBC_2.32 pthread_attr_getdetachstate F
+GLIBC_2.32 pthread_attr_getinheritsched F
+GLIBC_2.32 pthread_attr_getschedparam F
+GLIBC_2.32 pthread_attr_getschedpolicy F
+GLIBC_2.32 pthread_attr_getscope F
+GLIBC_2.32 pthread_attr_init F
+GLIBC_2.32 pthread_attr_setdetachstate F
+GLIBC_2.32 pthread_attr_setinheritsched F
+GLIBC_2.32 pthread_attr_setschedparam F
+GLIBC_2.32 pthread_attr_setschedpolicy F
+GLIBC_2.32 pthread_attr_setscope F
+GLIBC_2.32 pthread_cond_broadcast F
+GLIBC_2.32 pthread_cond_destroy F
+GLIBC_2.32 pthread_cond_init F
+GLIBC_2.32 pthread_cond_signal F
+GLIBC_2.32 pthread_cond_timedwait F
+GLIBC_2.32 pthread_cond_wait F
+GLIBC_2.32 pthread_condattr_destroy F
+GLIBC_2.32 pthread_condattr_init F
+GLIBC_2.32 pthread_equal F
+GLIBC_2.32 pthread_exit F
+GLIBC_2.32 pthread_getschedparam F
+GLIBC_2.32 pthread_mutex_destroy F
+GLIBC_2.32 pthread_mutex_init F
+GLIBC_2.32 pthread_mutex_lock F
+GLIBC_2.32 pthread_mutex_unlock F
+GLIBC_2.32 pthread_self F
+GLIBC_2.32 pthread_setcancelstate F
+GLIBC_2.32 pthread_setcanceltype F
+GLIBC_2.32 pthread_setschedparam F
+GLIBC_2.32 ptrace F
+GLIBC_2.32 ptsname F
+GLIBC_2.32 ptsname_r F
+GLIBC_2.32 putc F
+GLIBC_2.32 putc_unlocked F
+GLIBC_2.32 putchar F
+GLIBC_2.32 putchar_unlocked F
+GLIBC_2.32 putenv F
+GLIBC_2.32 putgrent F
+GLIBC_2.32 putpwent F
+GLIBC_2.32 puts F
+GLIBC_2.32 putsgent F
+GLIBC_2.32 putspent F
+GLIBC_2.32 pututline F
+GLIBC_2.32 pututxline F
+GLIBC_2.32 putw F
+GLIBC_2.32 putwc F
+GLIBC_2.32 putwc_unlocked F
+GLIBC_2.32 putwchar F
+GLIBC_2.32 putwchar_unlocked F
+GLIBC_2.32 pvalloc F
+GLIBC_2.32 pwrite F
+GLIBC_2.32 pwrite64 F
+GLIBC_2.32 pwritev F
+GLIBC_2.32 pwritev2 F
+GLIBC_2.32 pwritev64 F
+GLIBC_2.32 pwritev64v2 F
+GLIBC_2.32 qecvt F
+GLIBC_2.32 qecvt_r F
+GLIBC_2.32 qfcvt F
+GLIBC_2.32 qfcvt_r F
+GLIBC_2.32 qgcvt F
+GLIBC_2.32 qsort F
+GLIBC_2.32 qsort_r F
+GLIBC_2.32 quick_exit F
+GLIBC_2.32 quotactl F
+GLIBC_2.32 raise F
+GLIBC_2.32 rand F
+GLIBC_2.32 rand_r F
+GLIBC_2.32 random F
+GLIBC_2.32 random_r F
+GLIBC_2.32 rawmemchr F
+GLIBC_2.32 rcmd F
+GLIBC_2.32 rcmd_af F
+GLIBC_2.32 re_comp F
+GLIBC_2.32 re_compile_fastmap F
+GLIBC_2.32 re_compile_pattern F
+GLIBC_2.32 re_exec F
+GLIBC_2.32 re_match F
+GLIBC_2.32 re_match_2 F
+GLIBC_2.32 re_search F
+GLIBC_2.32 re_search_2 F
+GLIBC_2.32 re_set_registers F
+GLIBC_2.32 re_set_syntax F
+GLIBC_2.32 re_syntax_options D 0x4
+GLIBC_2.32 read F
+GLIBC_2.32 readahead F
+GLIBC_2.32 readdir F
+GLIBC_2.32 readdir64 F
+GLIBC_2.32 readdir64_r F
+GLIBC_2.32 readdir_r F
+GLIBC_2.32 readlink F
+GLIBC_2.32 readlinkat F
+GLIBC_2.32 readv F
+GLIBC_2.32 realloc F
+GLIBC_2.32 reallocarray F
+GLIBC_2.32 realpath F
+GLIBC_2.32 reboot F
+GLIBC_2.32 recv F
+GLIBC_2.32 recvfrom F
+GLIBC_2.32 recvmmsg F
+GLIBC_2.32 recvmsg F
+GLIBC_2.32 regcomp F
+GLIBC_2.32 regerror F
+GLIBC_2.32 regexec F
+GLIBC_2.32 regfree F
+GLIBC_2.32 register_printf_function F
+GLIBC_2.32 register_printf_modifier F
+GLIBC_2.32 register_printf_specifier F
+GLIBC_2.32 register_printf_type F
+GLIBC_2.32 registerrpc F
+GLIBC_2.32 remap_file_pages F
+GLIBC_2.32 remove F
+GLIBC_2.32 removexattr F
+GLIBC_2.32 remque F
+GLIBC_2.32 rename F
+GLIBC_2.32 renameat F
+GLIBC_2.32 renameat2 F
+GLIBC_2.32 revoke F
+GLIBC_2.32 rewind F
+GLIBC_2.32 rewinddir F
+GLIBC_2.32 rexec F
+GLIBC_2.32 rexec_af F
+GLIBC_2.32 rexecoptions D 0x4
+GLIBC_2.32 rindex F
+GLIBC_2.32 rmdir F
+GLIBC_2.32 rpc_createerr D 0x10
+GLIBC_2.32 rpmatch F
+GLIBC_2.32 rresvport F
+GLIBC_2.32 rresvport_af F
+GLIBC_2.32 rtime F
+GLIBC_2.32 ruserok F
+GLIBC_2.32 ruserok_af F
+GLIBC_2.32 ruserpass F
+GLIBC_2.32 sbrk F
+GLIBC_2.32 scalbn F
+GLIBC_2.32 scalbnf F
+GLIBC_2.32 scalbnl F
+GLIBC_2.32 scandir F
+GLIBC_2.32 scandir64 F
+GLIBC_2.32 scandirat F
+GLIBC_2.32 scandirat64 F
+GLIBC_2.32 scanf F
+GLIBC_2.32 sched_get_priority_max F
+GLIBC_2.32 sched_get_priority_min F
+GLIBC_2.32 sched_getaffinity F
+GLIBC_2.32 sched_getcpu F
+GLIBC_2.32 sched_getparam F
+GLIBC_2.32 sched_getscheduler F
+GLIBC_2.32 sched_rr_get_interval F
+GLIBC_2.32 sched_setaffinity F
+GLIBC_2.32 sched_setparam F
+GLIBC_2.32 sched_setscheduler F
+GLIBC_2.32 sched_yield F
+GLIBC_2.32 secure_getenv F
+GLIBC_2.32 seed48 F
+GLIBC_2.32 seed48_r F
+GLIBC_2.32 seekdir F
+GLIBC_2.32 select F
+GLIBC_2.32 semctl F
+GLIBC_2.32 semget F
+GLIBC_2.32 semop F
+GLIBC_2.32 semtimedop F
+GLIBC_2.32 send F
+GLIBC_2.32 sendfile F
+GLIBC_2.32 sendfile64 F
+GLIBC_2.32 sendmmsg F
+GLIBC_2.32 sendmsg F
+GLIBC_2.32 sendto F
+GLIBC_2.32 setaliasent F
+GLIBC_2.32 setbuf F
+GLIBC_2.32 setbuffer F
+GLIBC_2.32 setcontext F
+GLIBC_2.32 setdomainname F
+GLIBC_2.32 setegid F
+GLIBC_2.32 setenv F
+GLIBC_2.32 seteuid F
+GLIBC_2.32 setfsent F
+GLIBC_2.32 setfsgid F
+GLIBC_2.32 setfsuid F
+GLIBC_2.32 setgid F
+GLIBC_2.32 setgrent F
+GLIBC_2.32 setgroups F
+GLIBC_2.32 sethostent F
+GLIBC_2.32 sethostid F
+GLIBC_2.32 sethostname F
+GLIBC_2.32 setipv4sourcefilter F
+GLIBC_2.32 setitimer F
+GLIBC_2.32 setjmp F
+GLIBC_2.32 setlinebuf F
+GLIBC_2.32 setlocale F
+GLIBC_2.32 setlogin F
+GLIBC_2.32 setlogmask F
+GLIBC_2.32 setmntent F
+GLIBC_2.32 setnetent F
+GLIBC_2.32 setnetgrent F
+GLIBC_2.32 setns F
+GLIBC_2.32 setpgid F
+GLIBC_2.32 setpgrp F
+GLIBC_2.32 setpriority F
+GLIBC_2.32 setprotoent F
+GLIBC_2.32 setpwent F
+GLIBC_2.32 setregid F
+GLIBC_2.32 setresgid F
+GLIBC_2.32 setresuid F
+GLIBC_2.32 setreuid F
+GLIBC_2.32 setrlimit F
+GLIBC_2.32 setrlimit64 F
+GLIBC_2.32 setrpcent F
+GLIBC_2.32 setservent F
+GLIBC_2.32 setsgent F
+GLIBC_2.32 setsid F
+GLIBC_2.32 setsockopt F
+GLIBC_2.32 setsourcefilter F
+GLIBC_2.32 setspent F
+GLIBC_2.32 setstate F
+GLIBC_2.32 setstate_r F
+GLIBC_2.32 settimeofday F
+GLIBC_2.32 setttyent F
+GLIBC_2.32 setuid F
+GLIBC_2.32 setusershell F
+GLIBC_2.32 setutent F
+GLIBC_2.32 setutxent F
+GLIBC_2.32 setvbuf F
+GLIBC_2.32 setxattr F
+GLIBC_2.32 sgetsgent F
+GLIBC_2.32 sgetsgent_r F
+GLIBC_2.32 sgetspent F
+GLIBC_2.32 sgetspent_r F
+GLIBC_2.32 shmat F
+GLIBC_2.32 shmctl F
+GLIBC_2.32 shmdt F
+GLIBC_2.32 shmget F
+GLIBC_2.32 shutdown F
+GLIBC_2.32 sigaction F
+GLIBC_2.32 sigaddset F
+GLIBC_2.32 sigaltstack F
+GLIBC_2.32 sigandset F
+GLIBC_2.32 sigblock F
+GLIBC_2.32 sigdelset F
+GLIBC_2.32 sigemptyset F
+GLIBC_2.32 sigfillset F
+GLIBC_2.32 siggetmask F
+GLIBC_2.32 sighold F
+GLIBC_2.32 sigignore F
+GLIBC_2.32 siginterrupt F
+GLIBC_2.32 sigisemptyset F
+GLIBC_2.32 sigismember F
+GLIBC_2.32 siglongjmp F
+GLIBC_2.32 signal F
+GLIBC_2.32 signalfd F
+GLIBC_2.32 sigorset F
+GLIBC_2.32 sigpause F
+GLIBC_2.32 sigpending F
+GLIBC_2.32 sigprocmask F
+GLIBC_2.32 sigqueue F
+GLIBC_2.32 sigrelse F
+GLIBC_2.32 sigreturn F
+GLIBC_2.32 sigset F
+GLIBC_2.32 sigsetmask F
+GLIBC_2.32 sigstack F
+GLIBC_2.32 sigsuspend F
+GLIBC_2.32 sigtimedwait F
+GLIBC_2.32 sigwait F
+GLIBC_2.32 sigwaitinfo F
+GLIBC_2.32 sleep F
+GLIBC_2.32 snprintf F
+GLIBC_2.32 sockatmark F
+GLIBC_2.32 socket F
+GLIBC_2.32 socketpair F
+GLIBC_2.32 splice F
+GLIBC_2.32 sprintf F
+GLIBC_2.32 sprofil F
+GLIBC_2.32 srand F
+GLIBC_2.32 srand48 F
+GLIBC_2.32 srand48_r F
+GLIBC_2.32 srandom F
+GLIBC_2.32 srandom_r F
+GLIBC_2.32 sscanf F
+GLIBC_2.32 ssignal F
+GLIBC_2.32 sstk F
+GLIBC_2.32 statfs F
+GLIBC_2.32 statfs64 F
+GLIBC_2.32 statvfs F
+GLIBC_2.32 statvfs64 F
+GLIBC_2.32 statx F
+GLIBC_2.32 stderr D 0x4
+GLIBC_2.32 stdin D 0x4
+GLIBC_2.32 stdout D 0x4
+GLIBC_2.32 stime F
+GLIBC_2.32 stpcpy F
+GLIBC_2.32 stpncpy F
+GLIBC_2.32 strcasecmp F
+GLIBC_2.32 strcasecmp_l F
+GLIBC_2.32 strcasestr F
+GLIBC_2.32 strcat F
+GLIBC_2.32 strchr F
+GLIBC_2.32 strchrnul F
+GLIBC_2.32 strcmp F
+GLIBC_2.32 strcoll F
+GLIBC_2.32 strcoll_l F
+GLIBC_2.32 strcpy F
+GLIBC_2.32 strcspn F
+GLIBC_2.32 strdup F
+GLIBC_2.32 strerror F
+GLIBC_2.32 strerror_l F
+GLIBC_2.32 strerror_r F
+GLIBC_2.32 strfmon F
+GLIBC_2.32 strfmon_l F
+GLIBC_2.32 strfromd F
+GLIBC_2.32 strfromf F
+GLIBC_2.32 strfromf32 F
+GLIBC_2.32 strfromf32x F
+GLIBC_2.32 strfromf64 F
+GLIBC_2.32 strfroml F
+GLIBC_2.32 strfry F
+GLIBC_2.32 strftime F
+GLIBC_2.32 strftime_l F
+GLIBC_2.32 strlen F
+GLIBC_2.32 strncasecmp F
+GLIBC_2.32 strncasecmp_l F
+GLIBC_2.32 strncat F
+GLIBC_2.32 strncmp F
+GLIBC_2.32 strncpy F
+GLIBC_2.32 strndup F
+GLIBC_2.32 strnlen F
+GLIBC_2.32 strpbrk F
+GLIBC_2.32 strptime F
+GLIBC_2.32 strptime_l F
+GLIBC_2.32 strrchr F
+GLIBC_2.32 strsep F
+GLIBC_2.32 strsignal F
+GLIBC_2.32 strspn F
+GLIBC_2.32 strstr F
+GLIBC_2.32 strtod F
+GLIBC_2.32 strtod_l F
+GLIBC_2.32 strtof F
+GLIBC_2.32 strtof32 F
+GLIBC_2.32 strtof32_l F
+GLIBC_2.32 strtof32x F
+GLIBC_2.32 strtof32x_l F
+GLIBC_2.32 strtof64 F
+GLIBC_2.32 strtof64_l F
+GLIBC_2.32 strtof_l F
+GLIBC_2.32 strtoimax F
+GLIBC_2.32 strtok F
+GLIBC_2.32 strtok_r F
+GLIBC_2.32 strtol F
+GLIBC_2.32 strtol_l F
+GLIBC_2.32 strtold F
+GLIBC_2.32 strtold_l F
+GLIBC_2.32 strtoll F
+GLIBC_2.32 strtoll_l F
+GLIBC_2.32 strtoq F
+GLIBC_2.32 strtoul F
+GLIBC_2.32 strtoul_l F
+GLIBC_2.32 strtoull F
+GLIBC_2.32 strtoull_l F
+GLIBC_2.32 strtoumax F
+GLIBC_2.32 strtouq F
+GLIBC_2.32 strverscmp F
+GLIBC_2.32 strxfrm F
+GLIBC_2.32 strxfrm_l F
+GLIBC_2.32 stty F
+GLIBC_2.32 svc_exit F
+GLIBC_2.32 svc_fdset D 0x80
+GLIBC_2.32 svc_getreq F
+GLIBC_2.32 svc_getreq_common F
+GLIBC_2.32 svc_getreq_poll F
+GLIBC_2.32 svc_getreqset F
+GLIBC_2.32 svc_max_pollfd D 0x4
+GLIBC_2.32 svc_pollfd D 0x4
+GLIBC_2.32 svc_register F
+GLIBC_2.32 svc_run F
+GLIBC_2.32 svc_sendreply F
+GLIBC_2.32 svc_unregister F
+GLIBC_2.32 svcauthdes_stats D 0xc
+GLIBC_2.32 svcerr_auth F
+GLIBC_2.32 svcerr_decode F
+GLIBC_2.32 svcerr_noproc F
+GLIBC_2.32 svcerr_noprog F
+GLIBC_2.32 svcerr_progvers F
+GLIBC_2.32 svcerr_systemerr F
+GLIBC_2.32 svcerr_weakauth F
+GLIBC_2.32 svcfd_create F
+GLIBC_2.32 svcraw_create F
+GLIBC_2.32 svctcp_create F
+GLIBC_2.32 svcudp_bufcreate F
+GLIBC_2.32 svcudp_create F
+GLIBC_2.32 svcudp_enablecache F
+GLIBC_2.32 svcunix_create F
+GLIBC_2.32 svcunixfd_create F
+GLIBC_2.32 swab F
+GLIBC_2.32 swapcontext F
+GLIBC_2.32 swapoff F
+GLIBC_2.32 swapon F
+GLIBC_2.32 swprintf F
+GLIBC_2.32 swscanf F
+GLIBC_2.32 symlink F
+GLIBC_2.32 symlinkat F
+GLIBC_2.32 sync F
+GLIBC_2.32 sync_file_range F
+GLIBC_2.32 syncfs F
+GLIBC_2.32 sys_errlist D 0x21c
+GLIBC_2.32 sys_nerr D 0x4
+GLIBC_2.32 sys_sigabbrev D 0x104
+GLIBC_2.32 sys_siglist D 0x104
+GLIBC_2.32 syscall F
+GLIBC_2.32 sysconf F
+GLIBC_2.32 sysctl F
+GLIBC_2.32 sysinfo F
+GLIBC_2.32 syslog F
+GLIBC_2.32 system F
+GLIBC_2.32 sysv_signal F
+GLIBC_2.32 tcdrain F
+GLIBC_2.32 tcflow F
+GLIBC_2.32 tcflush F
+GLIBC_2.32 tcgetattr F
+GLIBC_2.32 tcgetpgrp F
+GLIBC_2.32 tcgetsid F
+GLIBC_2.32 tcsendbreak F
+GLIBC_2.32 tcsetattr F
+GLIBC_2.32 tcsetpgrp F
+GLIBC_2.32 tdelete F
+GLIBC_2.32 tdestroy F
+GLIBC_2.32 tee F
+GLIBC_2.32 telldir F
+GLIBC_2.32 tempnam F
+GLIBC_2.32 textdomain F
+GLIBC_2.32 tfind F
+GLIBC_2.32 tgkill F
+GLIBC_2.32 thrd_current F
+GLIBC_2.32 thrd_equal F
+GLIBC_2.32 thrd_sleep F
+GLIBC_2.32 thrd_yield F
+GLIBC_2.32 time F
+GLIBC_2.32 timegm F
+GLIBC_2.32 timelocal F
+GLIBC_2.32 timerfd_create F
+GLIBC_2.32 timerfd_gettime F
+GLIBC_2.32 timerfd_settime F
+GLIBC_2.32 times F
+GLIBC_2.32 timespec_get F
+GLIBC_2.32 timezone D 0x4
+GLIBC_2.32 tmpfile F
+GLIBC_2.32 tmpfile64 F
+GLIBC_2.32 tmpnam F
+GLIBC_2.32 tmpnam_r F
+GLIBC_2.32 toascii F
+GLIBC_2.32 tolower F
+GLIBC_2.32 tolower_l F
+GLIBC_2.32 toupper F
+GLIBC_2.32 toupper_l F
+GLIBC_2.32 towctrans F
+GLIBC_2.32 towctrans_l F
+GLIBC_2.32 towlower F
+GLIBC_2.32 towlower_l F
+GLIBC_2.32 towupper F
+GLIBC_2.32 towupper_l F
+GLIBC_2.32 tr_break F
+GLIBC_2.32 truncate F
+GLIBC_2.32 truncate64 F
+GLIBC_2.32 tsearch F
+GLIBC_2.32 ttyname F
+GLIBC_2.32 ttyname_r F
+GLIBC_2.32 ttyslot F
+GLIBC_2.32 twalk F
+GLIBC_2.32 twalk_r F
+GLIBC_2.32 tzname D 0x8
+GLIBC_2.32 tzset F
+GLIBC_2.32 ualarm F
+GLIBC_2.32 ulckpwdf F
+GLIBC_2.32 ulimit F
+GLIBC_2.32 umask F
+GLIBC_2.32 umount F
+GLIBC_2.32 umount2 F
+GLIBC_2.32 uname F
+GLIBC_2.32 ungetc F
+GLIBC_2.32 ungetwc F
+GLIBC_2.32 unlink F
+GLIBC_2.32 unlinkat F
+GLIBC_2.32 unlockpt F
+GLIBC_2.32 unsetenv F
+GLIBC_2.32 unshare F
+GLIBC_2.32 updwtmp F
+GLIBC_2.32 updwtmpx F
+GLIBC_2.32 uselocale F
+GLIBC_2.32 user2netname F
+GLIBC_2.32 usleep F
+GLIBC_2.32 utime F
+GLIBC_2.32 utimensat F
+GLIBC_2.32 utimes F
+GLIBC_2.32 utmpname F
+GLIBC_2.32 utmpxname F
+GLIBC_2.32 valloc F
+GLIBC_2.32 vasprintf F
+GLIBC_2.32 vdprintf F
+GLIBC_2.32 verr F
+GLIBC_2.32 verrx F
+GLIBC_2.32 versionsort F
+GLIBC_2.32 versionsort64 F
+GLIBC_2.32 vfork F
+GLIBC_2.32 vfprintf F
+GLIBC_2.32 vfscanf F
+GLIBC_2.32 vfwprintf F
+GLIBC_2.32 vfwscanf F
+GLIBC_2.32 vhangup F
+GLIBC_2.32 vlimit F
+GLIBC_2.32 vmsplice F
+GLIBC_2.32 vprintf F
+GLIBC_2.32 vscanf F
+GLIBC_2.32 vsnprintf F
+GLIBC_2.32 vsprintf F
+GLIBC_2.32 vsscanf F
+GLIBC_2.32 vswprintf F
+GLIBC_2.32 vswscanf F
+GLIBC_2.32 vsyslog F
+GLIBC_2.32 vtimes F
+GLIBC_2.32 vwarn F
+GLIBC_2.32 vwarnx F
+GLIBC_2.32 vwprintf F
+GLIBC_2.32 vwscanf F
+GLIBC_2.32 wait F
+GLIBC_2.32 wait3 F
+GLIBC_2.32 wait4 F
+GLIBC_2.32 waitid F
+GLIBC_2.32 waitpid F
+GLIBC_2.32 warn F
+GLIBC_2.32 warnx F
+GLIBC_2.32 wcpcpy F
+GLIBC_2.32 wcpncpy F
+GLIBC_2.32 wcrtomb F
+GLIBC_2.32 wcscasecmp F
+GLIBC_2.32 wcscasecmp_l F
+GLIBC_2.32 wcscat F
+GLIBC_2.32 wcschr F
+GLIBC_2.32 wcschrnul F
+GLIBC_2.32 wcscmp F
+GLIBC_2.32 wcscoll F
+GLIBC_2.32 wcscoll_l F
+GLIBC_2.32 wcscpy F
+GLIBC_2.32 wcscspn F
+GLIBC_2.32 wcsdup F
+GLIBC_2.32 wcsftime F
+GLIBC_2.32 wcsftime_l F
+GLIBC_2.32 wcslen F
+GLIBC_2.32 wcsncasecmp F
+GLIBC_2.32 wcsncasecmp_l F
+GLIBC_2.32 wcsncat F
+GLIBC_2.32 wcsncmp F
+GLIBC_2.32 wcsncpy F
+GLIBC_2.32 wcsnlen F
+GLIBC_2.32 wcsnrtombs F
+GLIBC_2.32 wcspbrk F
+GLIBC_2.32 wcsrchr F
+GLIBC_2.32 wcsrtombs F
+GLIBC_2.32 wcsspn F
+GLIBC_2.32 wcsstr F
+GLIBC_2.32 wcstod F
+GLIBC_2.32 wcstod_l F
+GLIBC_2.32 wcstof F
+GLIBC_2.32 wcstof32 F
+GLIBC_2.32 wcstof32_l F
+GLIBC_2.32 wcstof32x F
+GLIBC_2.32 wcstof32x_l F
+GLIBC_2.32 wcstof64 F
+GLIBC_2.32 wcstof64_l F
+GLIBC_2.32 wcstof_l F
+GLIBC_2.32 wcstoimax F
+GLIBC_2.32 wcstok F
+GLIBC_2.32 wcstol F
+GLIBC_2.32 wcstol_l F
+GLIBC_2.32 wcstold F
+GLIBC_2.32 wcstold_l F
+GLIBC_2.32 wcstoll F
+GLIBC_2.32 wcstoll_l F
+GLIBC_2.32 wcstombs F
+GLIBC_2.32 wcstoq F
+GLIBC_2.32 wcstoul F
+GLIBC_2.32 wcstoul_l F
+GLIBC_2.32 wcstoull F
+GLIBC_2.32 wcstoull_l F
+GLIBC_2.32 wcstoumax F
+GLIBC_2.32 wcstouq F
+GLIBC_2.32 wcswcs F
+GLIBC_2.32 wcswidth F
+GLIBC_2.32 wcsxfrm F
+GLIBC_2.32 wcsxfrm_l F
+GLIBC_2.32 wctob F
+GLIBC_2.32 wctomb F
+GLIBC_2.32 wctrans F
+GLIBC_2.32 wctrans_l F
+GLIBC_2.32 wctype F
+GLIBC_2.32 wctype_l F
+GLIBC_2.32 wcwidth F
+GLIBC_2.32 wmemchr F
+GLIBC_2.32 wmemcmp F
+GLIBC_2.32 wmemcpy F
+GLIBC_2.32 wmemmove F
+GLIBC_2.32 wmempcpy F
+GLIBC_2.32 wmemset F
+GLIBC_2.32 wordexp F
+GLIBC_2.32 wordfree F
+GLIBC_2.32 wprintf F
+GLIBC_2.32 write F
+GLIBC_2.32 writev F
+GLIBC_2.32 wscanf F
+GLIBC_2.32 xdecrypt F
+GLIBC_2.32 xdr_accepted_reply F
+GLIBC_2.32 xdr_array F
+GLIBC_2.32 xdr_authdes_cred F
+GLIBC_2.32 xdr_authdes_verf F
+GLIBC_2.32 xdr_authunix_parms F
+GLIBC_2.32 xdr_bool F
+GLIBC_2.32 xdr_bytes F
+GLIBC_2.32 xdr_callhdr F
+GLIBC_2.32 xdr_callmsg F
+GLIBC_2.32 xdr_char F
+GLIBC_2.32 xdr_cryptkeyarg F
+GLIBC_2.32 xdr_cryptkeyarg2 F
+GLIBC_2.32 xdr_cryptkeyres F
+GLIBC_2.32 xdr_des_block F
+GLIBC_2.32 xdr_double F
+GLIBC_2.32 xdr_enum F
+GLIBC_2.32 xdr_float F
+GLIBC_2.32 xdr_free F
+GLIBC_2.32 xdr_getcredres F
+GLIBC_2.32 xdr_hyper F
+GLIBC_2.32 xdr_int F
+GLIBC_2.32 xdr_int16_t F
+GLIBC_2.32 xdr_int32_t F
+GLIBC_2.32 xdr_int64_t F
+GLIBC_2.32 xdr_int8_t F
+GLIBC_2.32 xdr_key_netstarg F
+GLIBC_2.32 xdr_key_netstres F
+GLIBC_2.32 xdr_keybuf F
+GLIBC_2.32 xdr_keystatus F
+GLIBC_2.32 xdr_long F
+GLIBC_2.32 xdr_longlong_t F
+GLIBC_2.32 xdr_netnamestr F
+GLIBC_2.32 xdr_netobj F
+GLIBC_2.32 xdr_opaque F
+GLIBC_2.32 xdr_opaque_auth F
+GLIBC_2.32 xdr_pmap F
+GLIBC_2.32 xdr_pmaplist F
+GLIBC_2.32 xdr_pointer F
+GLIBC_2.32 xdr_quad_t F
+GLIBC_2.32 xdr_reference F
+GLIBC_2.32 xdr_rejected_reply F
+GLIBC_2.32 xdr_replymsg F
+GLIBC_2.32 xdr_rmtcall_args F
+GLIBC_2.32 xdr_rmtcallres F
+GLIBC_2.32 xdr_short F
+GLIBC_2.32 xdr_sizeof F
+GLIBC_2.32 xdr_string F
+GLIBC_2.32 xdr_u_char F
+GLIBC_2.32 xdr_u_hyper F
+GLIBC_2.32 xdr_u_int F
+GLIBC_2.32 xdr_u_long F
+GLIBC_2.32 xdr_u_longlong_t F
+GLIBC_2.32 xdr_u_quad_t F
+GLIBC_2.32 xdr_u_short F
+GLIBC_2.32 xdr_uint16_t F
+GLIBC_2.32 xdr_uint32_t F
+GLIBC_2.32 xdr_uint64_t F
+GLIBC_2.32 xdr_uint8_t F
+GLIBC_2.32 xdr_union F
+GLIBC_2.32 xdr_unixcred F
+GLIBC_2.32 xdr_vector F
+GLIBC_2.32 xdr_void F
+GLIBC_2.32 xdr_wrapstring F
+GLIBC_2.32 xdrmem_create F
+GLIBC_2.32 xdrrec_create F
+GLIBC_2.32 xdrrec_endofrecord F
+GLIBC_2.32 xdrrec_eof F
+GLIBC_2.32 xdrrec_skiprecord F
+GLIBC_2.32 xdrstdio_create F
+GLIBC_2.32 xencrypt F
+GLIBC_2.32 xprt_register F
+GLIBC_2.32 xprt_unregister F
diff --git a/sysdeps/unix/sysv/linux/arc/libcrypt.abilist b/sysdeps/unix/sysv/linux/arc/libcrypt.abilist
new file mode 100644
index 000000000000..6bd253453e99
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libcrypt.abilist
@@ -0,0 +1,2 @@
+GLIBC_2.32 crypt F
+GLIBC_2.32 crypt_r F
diff --git a/sysdeps/unix/sysv/linux/arc/libdl.abilist b/sysdeps/unix/sysv/linux/arc/libdl.abilist
new file mode 100644
index 000000000000..bf20b0c4044f
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libdl.abilist
@@ -0,0 +1,9 @@
+GLIBC_2.32 dladdr F
+GLIBC_2.32 dladdr1 F
+GLIBC_2.32 dlclose F
+GLIBC_2.32 dlerror F
+GLIBC_2.32 dlinfo F
+GLIBC_2.32 dlmopen F
+GLIBC_2.32 dlopen F
+GLIBC_2.32 dlsym F
+GLIBC_2.32 dlvsym F
diff --git a/sysdeps/unix/sysv/linux/arc/libm.abilist b/sysdeps/unix/sysv/linux/arc/libm.abilist
new file mode 100644
index 000000000000..6a51f2dad577
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libm.abilist
@@ -0,0 +1,765 @@
+GLIBC_2.32 __acos_finite F
+GLIBC_2.32 __acosf_finite F
+GLIBC_2.32 __acosh_finite F
+GLIBC_2.32 __acoshf_finite F
+GLIBC_2.32 __asin_finite F
+GLIBC_2.32 __asinf_finite F
+GLIBC_2.32 __atan2_finite F
+GLIBC_2.32 __atan2f_finite F
+GLIBC_2.32 __atanh_finite F
+GLIBC_2.32 __atanhf_finite F
+GLIBC_2.32 __clog10 F
+GLIBC_2.32 __clog10f F
+GLIBC_2.32 __clog10l F
+GLIBC_2.32 __cosh_finite F
+GLIBC_2.32 __coshf_finite F
+GLIBC_2.32 __exp10_finite F
+GLIBC_2.32 __exp10f_finite F
+GLIBC_2.32 __exp2_finite F
+GLIBC_2.32 __exp2f_finite F
+GLIBC_2.32 __exp_finite F
+GLIBC_2.32 __expf_finite F
+GLIBC_2.32 __finite F
+GLIBC_2.32 __finitef F
+GLIBC_2.32 __fmod_finite F
+GLIBC_2.32 __fmodf_finite F
+GLIBC_2.32 __fpclassify F
+GLIBC_2.32 __fpclassifyf F
+GLIBC_2.32 __gamma_r_finite F
+GLIBC_2.32 __gammaf_r_finite F
+GLIBC_2.32 __hypot_finite F
+GLIBC_2.32 __hypotf_finite F
+GLIBC_2.32 __iseqsig F
+GLIBC_2.32 __iseqsigf F
+GLIBC_2.32 __issignaling F
+GLIBC_2.32 __issignalingf F
+GLIBC_2.32 __j0_finite F
+GLIBC_2.32 __j0f_finite F
+GLIBC_2.32 __j1_finite F
+GLIBC_2.32 __j1f_finite F
+GLIBC_2.32 __jn_finite F
+GLIBC_2.32 __jnf_finite F
+GLIBC_2.32 __lgamma_r_finite F
+GLIBC_2.32 __lgammaf_r_finite F
+GLIBC_2.32 __log10_finite F
+GLIBC_2.32 __log10f_finite F
+GLIBC_2.32 __log2_finite F
+GLIBC_2.32 __log2f_finite F
+GLIBC_2.32 __log_finite F
+GLIBC_2.32 __logf_finite F
+GLIBC_2.32 __pow_finite F
+GLIBC_2.32 __powf_finite F
+GLIBC_2.32 __remainder_finite F
+GLIBC_2.32 __remainderf_finite F
+GLIBC_2.32 __scalb_finite F
+GLIBC_2.32 __scalbf_finite F
+GLIBC_2.32 __signbit F
+GLIBC_2.32 __signbitf F
+GLIBC_2.32 __signgam D 0x4
+GLIBC_2.32 __sinh_finite F
+GLIBC_2.32 __sinhf_finite F
+GLIBC_2.32 __sqrt_finite F
+GLIBC_2.32 __sqrtf_finite F
+GLIBC_2.32 __y0_finite F
+GLIBC_2.32 __y0f_finite F
+GLIBC_2.32 __y1_finite F
+GLIBC_2.32 __y1f_finite F
+GLIBC_2.32 __yn_finite F
+GLIBC_2.32 __ynf_finite F
+GLIBC_2.32 acos F
+GLIBC_2.32 acosf F
+GLIBC_2.32 acosf32 F
+GLIBC_2.32 acosf32x F
+GLIBC_2.32 acosf64 F
+GLIBC_2.32 acosh F
+GLIBC_2.32 acoshf F
+GLIBC_2.32 acoshf32 F
+GLIBC_2.32 acoshf32x F
+GLIBC_2.32 acoshf64 F
+GLIBC_2.32 acoshl F
+GLIBC_2.32 acosl F
+GLIBC_2.32 asin F
+GLIBC_2.32 asinf F
+GLIBC_2.32 asinf32 F
+GLIBC_2.32 asinf32x F
+GLIBC_2.32 asinf64 F
+GLIBC_2.32 asinh F
+GLIBC_2.32 asinhf F
+GLIBC_2.32 asinhf32 F
+GLIBC_2.32 asinhf32x F
+GLIBC_2.32 asinhf64 F
+GLIBC_2.32 asinhl F
+GLIBC_2.32 asinl F
+GLIBC_2.32 atan F
+GLIBC_2.32 atan2 F
+GLIBC_2.32 atan2f F
+GLIBC_2.32 atan2f32 F
+GLIBC_2.32 atan2f32x F
+GLIBC_2.32 atan2f64 F
+GLIBC_2.32 atan2l F
+GLIBC_2.32 atanf F
+GLIBC_2.32 atanf32 F
+GLIBC_2.32 atanf32x F
+GLIBC_2.32 atanf64 F
+GLIBC_2.32 atanh F
+GLIBC_2.32 atanhf F
+GLIBC_2.32 atanhf32 F
+GLIBC_2.32 atanhf32x F
+GLIBC_2.32 atanhf64 F
+GLIBC_2.32 atanhl F
+GLIBC_2.32 atanl F
+GLIBC_2.32 cabs F
+GLIBC_2.32 cabsf F
+GLIBC_2.32 cabsf32 F
+GLIBC_2.32 cabsf32x F
+GLIBC_2.32 cabsf64 F
+GLIBC_2.32 cabsl F
+GLIBC_2.32 cacos F
+GLIBC_2.32 cacosf F
+GLIBC_2.32 cacosf32 F
+GLIBC_2.32 cacosf32x F
+GLIBC_2.32 cacosf64 F
+GLIBC_2.32 cacosh F
+GLIBC_2.32 cacoshf F
+GLIBC_2.32 cacoshf32 F
+GLIBC_2.32 cacoshf32x F
+GLIBC_2.32 cacoshf64 F
+GLIBC_2.32 cacoshl F
+GLIBC_2.32 cacosl F
+GLIBC_2.32 canonicalize F
+GLIBC_2.32 canonicalizef F
+GLIBC_2.32 canonicalizef32 F
+GLIBC_2.32 canonicalizef32x F
+GLIBC_2.32 canonicalizef64 F
+GLIBC_2.32 canonicalizel F
+GLIBC_2.32 carg F
+GLIBC_2.32 cargf F
+GLIBC_2.32 cargf32 F
+GLIBC_2.32 cargf32x F
+GLIBC_2.32 cargf64 F
+GLIBC_2.32 cargl F
+GLIBC_2.32 casin F
+GLIBC_2.32 casinf F
+GLIBC_2.32 casinf32 F
+GLIBC_2.32 casinf32x F
+GLIBC_2.32 casinf64 F
+GLIBC_2.32 casinh F
+GLIBC_2.32 casinhf F
+GLIBC_2.32 casinhf32 F
+GLIBC_2.32 casinhf32x F
+GLIBC_2.32 casinhf64 F
+GLIBC_2.32 casinhl F
+GLIBC_2.32 casinl F
+GLIBC_2.32 catan F
+GLIBC_2.32 catanf F
+GLIBC_2.32 catanf32 F
+GLIBC_2.32 catanf32x F
+GLIBC_2.32 catanf64 F
+GLIBC_2.32 catanh F
+GLIBC_2.32 catanhf F
+GLIBC_2.32 catanhf32 F
+GLIBC_2.32 catanhf32x F
+GLIBC_2.32 catanhf64 F
+GLIBC_2.32 catanhl F
+GLIBC_2.32 catanl F
+GLIBC_2.32 cbrt F
+GLIBC_2.32 cbrtf F
+GLIBC_2.32 cbrtf32 F
+GLIBC_2.32 cbrtf32x F
+GLIBC_2.32 cbrtf64 F
+GLIBC_2.32 cbrtl F
+GLIBC_2.32 ccos F
+GLIBC_2.32 ccosf F
+GLIBC_2.32 ccosf32 F
+GLIBC_2.32 ccosf32x F
+GLIBC_2.32 ccosf64 F
+GLIBC_2.32 ccosh F
+GLIBC_2.32 ccoshf F
+GLIBC_2.32 ccoshf32 F
+GLIBC_2.32 ccoshf32x F
+GLIBC_2.32 ccoshf64 F
+GLIBC_2.32 ccoshl F
+GLIBC_2.32 ccosl F
+GLIBC_2.32 ceil F
+GLIBC_2.32 ceilf F
+GLIBC_2.32 ceilf32 F
+GLIBC_2.32 ceilf32x F
+GLIBC_2.32 ceilf64 F
+GLIBC_2.32 ceill F
+GLIBC_2.32 cexp F
+GLIBC_2.32 cexpf F
+GLIBC_2.32 cexpf32 F
+GLIBC_2.32 cexpf32x F
+GLIBC_2.32 cexpf64 F
+GLIBC_2.32 cexpl F
+GLIBC_2.32 cimag F
+GLIBC_2.32 cimagf F
+GLIBC_2.32 cimagf32 F
+GLIBC_2.32 cimagf32x F
+GLIBC_2.32 cimagf64 F
+GLIBC_2.32 cimagl F
+GLIBC_2.32 clog F
+GLIBC_2.32 clog10 F
+GLIBC_2.32 clog10f F
+GLIBC_2.32 clog10f32 F
+GLIBC_2.32 clog10f32x F
+GLIBC_2.32 clog10f64 F
+GLIBC_2.32 clog10l F
+GLIBC_2.32 clogf F
+GLIBC_2.32 clogf32 F
+GLIBC_2.32 clogf32x F
+GLIBC_2.32 clogf64 F
+GLIBC_2.32 clogl F
+GLIBC_2.32 conj F
+GLIBC_2.32 conjf F
+GLIBC_2.32 conjf32 F
+GLIBC_2.32 conjf32x F
+GLIBC_2.32 conjf64 F
+GLIBC_2.32 conjl F
+GLIBC_2.32 copysign F
+GLIBC_2.32 copysignf F
+GLIBC_2.32 copysignf32 F
+GLIBC_2.32 copysignf32x F
+GLIBC_2.32 copysignf64 F
+GLIBC_2.32 copysignl F
+GLIBC_2.32 cos F
+GLIBC_2.32 cosf F
+GLIBC_2.32 cosf32 F
+GLIBC_2.32 cosf32x F
+GLIBC_2.32 cosf64 F
+GLIBC_2.32 cosh F
+GLIBC_2.32 coshf F
+GLIBC_2.32 coshf32 F
+GLIBC_2.32 coshf32x F
+GLIBC_2.32 coshf64 F
+GLIBC_2.32 coshl F
+GLIBC_2.32 cosl F
+GLIBC_2.32 cpow F
+GLIBC_2.32 cpowf F
+GLIBC_2.32 cpowf32 F
+GLIBC_2.32 cpowf32x F
+GLIBC_2.32 cpowf64 F
+GLIBC_2.32 cpowl F
+GLIBC_2.32 cproj F
+GLIBC_2.32 cprojf F
+GLIBC_2.32 cprojf32 F
+GLIBC_2.32 cprojf32x F
+GLIBC_2.32 cprojf64 F
+GLIBC_2.32 cprojl F
+GLIBC_2.32 creal F
+GLIBC_2.32 crealf F
+GLIBC_2.32 crealf32 F
+GLIBC_2.32 crealf32x F
+GLIBC_2.32 crealf64 F
+GLIBC_2.32 creall F
+GLIBC_2.32 csin F
+GLIBC_2.32 csinf F
+GLIBC_2.32 csinf32 F
+GLIBC_2.32 csinf32x F
+GLIBC_2.32 csinf64 F
+GLIBC_2.32 csinh F
+GLIBC_2.32 csinhf F
+GLIBC_2.32 csinhf32 F
+GLIBC_2.32 csinhf32x F
+GLIBC_2.32 csinhf64 F
+GLIBC_2.32 csinhl F
+GLIBC_2.32 csinl F
+GLIBC_2.32 csqrt F
+GLIBC_2.32 csqrtf F
+GLIBC_2.32 csqrtf32 F
+GLIBC_2.32 csqrtf32x F
+GLIBC_2.32 csqrtf64 F
+GLIBC_2.32 csqrtl F
+GLIBC_2.32 ctan F
+GLIBC_2.32 ctanf F
+GLIBC_2.32 ctanf32 F
+GLIBC_2.32 ctanf32x F
+GLIBC_2.32 ctanf64 F
+GLIBC_2.32 ctanh F
+GLIBC_2.32 ctanhf F
+GLIBC_2.32 ctanhf32 F
+GLIBC_2.32 ctanhf32x F
+GLIBC_2.32 ctanhf64 F
+GLIBC_2.32 ctanhl F
+GLIBC_2.32 ctanl F
+GLIBC_2.32 daddl F
+GLIBC_2.32 ddivl F
+GLIBC_2.32 dmull F
+GLIBC_2.32 drem F
+GLIBC_2.32 dremf F
+GLIBC_2.32 dreml F
+GLIBC_2.32 dsubl F
+GLIBC_2.32 erf F
+GLIBC_2.32 erfc F
+GLIBC_2.32 erfcf F
+GLIBC_2.32 erfcf32 F
+GLIBC_2.32 erfcf32x F
+GLIBC_2.32 erfcf64 F
+GLIBC_2.32 erfcl F
+GLIBC_2.32 erff F
+GLIBC_2.32 erff32 F
+GLIBC_2.32 erff32x F
+GLIBC_2.32 erff64 F
+GLIBC_2.32 erfl F
+GLIBC_2.32 exp F
+GLIBC_2.32 exp10 F
+GLIBC_2.32 exp10f F
+GLIBC_2.32 exp10f32 F
+GLIBC_2.32 exp10f32x F
+GLIBC_2.32 exp10f64 F
+GLIBC_2.32 exp10l F
+GLIBC_2.32 exp2 F
+GLIBC_2.32 exp2f F
+GLIBC_2.32 exp2f32 F
+GLIBC_2.32 exp2f32x F
+GLIBC_2.32 exp2f64 F
+GLIBC_2.32 exp2l F
+GLIBC_2.32 expf F
+GLIBC_2.32 expf32 F
+GLIBC_2.32 expf32x F
+GLIBC_2.32 expf64 F
+GLIBC_2.32 expl F
+GLIBC_2.32 expm1 F
+GLIBC_2.32 expm1f F
+GLIBC_2.32 expm1f32 F
+GLIBC_2.32 expm1f32x F
+GLIBC_2.32 expm1f64 F
+GLIBC_2.32 expm1l F
+GLIBC_2.32 f32addf32x F
+GLIBC_2.32 f32addf64 F
+GLIBC_2.32 f32divf32x F
+GLIBC_2.32 f32divf64 F
+GLIBC_2.32 f32mulf32x F
+GLIBC_2.32 f32mulf64 F
+GLIBC_2.32 f32subf32x F
+GLIBC_2.32 f32subf64 F
+GLIBC_2.32 f32xaddf64 F
+GLIBC_2.32 f32xdivf64 F
+GLIBC_2.32 f32xmulf64 F
+GLIBC_2.32 f32xsubf64 F
+GLIBC_2.32 fabs F
+GLIBC_2.32 fabsf F
+GLIBC_2.32 fabsf32 F
+GLIBC_2.32 fabsf32x F
+GLIBC_2.32 fabsf64 F
+GLIBC_2.32 fabsl F
+GLIBC_2.32 fadd F
+GLIBC_2.32 faddl F
+GLIBC_2.32 fdim F
+GLIBC_2.32 fdimf F
+GLIBC_2.32 fdimf32 F
+GLIBC_2.32 fdimf32x F
+GLIBC_2.32 fdimf64 F
+GLIBC_2.32 fdiml F
+GLIBC_2.32 fdiv F
+GLIBC_2.32 fdivl F
+GLIBC_2.32 feclearexcept F
+GLIBC_2.32 fedisableexcept F
+GLIBC_2.32 feenableexcept F
+GLIBC_2.32 fegetenv F
+GLIBC_2.32 fegetexcept F
+GLIBC_2.32 fegetexceptflag F
+GLIBC_2.32 fegetmode F
+GLIBC_2.32 fegetround F
+GLIBC_2.32 feholdexcept F
+GLIBC_2.32 feraiseexcept F
+GLIBC_2.32 fesetenv F
+GLIBC_2.32 fesetexcept F
+GLIBC_2.32 fesetexceptflag F
+GLIBC_2.32 fesetmode F
+GLIBC_2.32 fesetround F
+GLIBC_2.32 fetestexcept F
+GLIBC_2.32 fetestexceptflag F
+GLIBC_2.32 feupdateenv F
+GLIBC_2.32 finite F
+GLIBC_2.32 finitef F
+GLIBC_2.32 finitel F
+GLIBC_2.32 floor F
+GLIBC_2.32 floorf F
+GLIBC_2.32 floorf32 F
+GLIBC_2.32 floorf32x F
+GLIBC_2.32 floorf64 F
+GLIBC_2.32 floorl F
+GLIBC_2.32 fma F
+GLIBC_2.32 fmaf F
+GLIBC_2.32 fmaf32 F
+GLIBC_2.32 fmaf32x F
+GLIBC_2.32 fmaf64 F
+GLIBC_2.32 fmal F
+GLIBC_2.32 fmax F
+GLIBC_2.32 fmaxf F
+GLIBC_2.32 fmaxf32 F
+GLIBC_2.32 fmaxf32x F
+GLIBC_2.32 fmaxf64 F
+GLIBC_2.32 fmaxl F
+GLIBC_2.32 fmaxmag F
+GLIBC_2.32 fmaxmagf F
+GLIBC_2.32 fmaxmagf32 F
+GLIBC_2.32 fmaxmagf32x F
+GLIBC_2.32 fmaxmagf64 F
+GLIBC_2.32 fmaxmagl F
+GLIBC_2.32 fmin F
+GLIBC_2.32 fminf F
+GLIBC_2.32 fminf32 F
+GLIBC_2.32 fminf32x F
+GLIBC_2.32 fminf64 F
+GLIBC_2.32 fminl F
+GLIBC_2.32 fminmag F
+GLIBC_2.32 fminmagf F
+GLIBC_2.32 fminmagf32 F
+GLIBC_2.32 fminmagf32x F
+GLIBC_2.32 fminmagf64 F
+GLIBC_2.32 fminmagl F
+GLIBC_2.32 fmod F
+GLIBC_2.32 fmodf F
+GLIBC_2.32 fmodf32 F
+GLIBC_2.32 fmodf32x F
+GLIBC_2.32 fmodf64 F
+GLIBC_2.32 fmodl F
+GLIBC_2.32 fmul F
+GLIBC_2.32 fmull F
+GLIBC_2.32 frexp F
+GLIBC_2.32 frexpf F
+GLIBC_2.32 frexpf32 F
+GLIBC_2.32 frexpf32x F
+GLIBC_2.32 frexpf64 F
+GLIBC_2.32 frexpl F
+GLIBC_2.32 fromfp F
+GLIBC_2.32 fromfpf F
+GLIBC_2.32 fromfpf32 F
+GLIBC_2.32 fromfpf32x F
+GLIBC_2.32 fromfpf64 F
+GLIBC_2.32 fromfpl F
+GLIBC_2.32 fromfpx F
+GLIBC_2.32 fromfpxf F
+GLIBC_2.32 fromfpxf32 F
+GLIBC_2.32 fromfpxf32x F
+GLIBC_2.32 fromfpxf64 F
+GLIBC_2.32 fromfpxl F
+GLIBC_2.32 fsub F
+GLIBC_2.32 fsubl F
+GLIBC_2.32 gamma F
+GLIBC_2.32 gammaf F
+GLIBC_2.32 gammal F
+GLIBC_2.32 getpayload F
+GLIBC_2.32 getpayloadf F
+GLIBC_2.32 getpayloadf32 F
+GLIBC_2.32 getpayloadf32x F
+GLIBC_2.32 getpayloadf64 F
+GLIBC_2.32 getpayloadl F
+GLIBC_2.32 hypot F
+GLIBC_2.32 hypotf F
+GLIBC_2.32 hypotf32 F
+GLIBC_2.32 hypotf32x F
+GLIBC_2.32 hypotf64 F
+GLIBC_2.32 hypotl F
+GLIBC_2.32 ilogb F
+GLIBC_2.32 ilogbf F
+GLIBC_2.32 ilogbf32 F
+GLIBC_2.32 ilogbf32x F
+GLIBC_2.32 ilogbf64 F
+GLIBC_2.32 ilogbl F
+GLIBC_2.32 j0 F
+GLIBC_2.32 j0f F
+GLIBC_2.32 j0f32 F
+GLIBC_2.32 j0f32x F
+GLIBC_2.32 j0f64 F
+GLIBC_2.32 j0l F
+GLIBC_2.32 j1 F
+GLIBC_2.32 j1f F
+GLIBC_2.32 j1f32 F
+GLIBC_2.32 j1f32x F
+GLIBC_2.32 j1f64 F
+GLIBC_2.32 j1l F
+GLIBC_2.32 jn F
+GLIBC_2.32 jnf F
+GLIBC_2.32 jnf32 F
+GLIBC_2.32 jnf32x F
+GLIBC_2.32 jnf64 F
+GLIBC_2.32 jnl F
+GLIBC_2.32 ldexp F
+GLIBC_2.32 ldexpf F
+GLIBC_2.32 ldexpf32 F
+GLIBC_2.32 ldexpf32x F
+GLIBC_2.32 ldexpf64 F
+GLIBC_2.32 ldexpl F
+GLIBC_2.32 lgamma F
+GLIBC_2.32 lgamma_r F
+GLIBC_2.32 lgammaf F
+GLIBC_2.32 lgammaf32 F
+GLIBC_2.32 lgammaf32_r F
+GLIBC_2.32 lgammaf32x F
+GLIBC_2.32 lgammaf32x_r F
+GLIBC_2.32 lgammaf64 F
+GLIBC_2.32 lgammaf64_r F
+GLIBC_2.32 lgammaf_r F
+GLIBC_2.32 lgammal F
+GLIBC_2.32 lgammal_r F
+GLIBC_2.32 llogb F
+GLIBC_2.32 llogbf F
+GLIBC_2.32 llogbf32 F
+GLIBC_2.32 llogbf32x F
+GLIBC_2.32 llogbf64 F
+GLIBC_2.32 llogbl F
+GLIBC_2.32 llrint F
+GLIBC_2.32 llrintf F
+GLIBC_2.32 llrintf32 F
+GLIBC_2.32 llrintf32x F
+GLIBC_2.32 llrintf64 F
+GLIBC_2.32 llrintl F
+GLIBC_2.32 llround F
+GLIBC_2.32 llroundf F
+GLIBC_2.32 llroundf32 F
+GLIBC_2.32 llroundf32x F
+GLIBC_2.32 llroundf64 F
+GLIBC_2.32 llroundl F
+GLIBC_2.32 log F
+GLIBC_2.32 log10 F
+GLIBC_2.32 log10f F
+GLIBC_2.32 log10f32 F
+GLIBC_2.32 log10f32x F
+GLIBC_2.32 log10f64 F
+GLIBC_2.32 log10l F
+GLIBC_2.32 log1p F
+GLIBC_2.32 log1pf F
+GLIBC_2.32 log1pf32 F
+GLIBC_2.32 log1pf32x F
+GLIBC_2.32 log1pf64 F
+GLIBC_2.32 log1pl F
+GLIBC_2.32 log2 F
+GLIBC_2.32 log2f F
+GLIBC_2.32 log2f32 F
+GLIBC_2.32 log2f32x F
+GLIBC_2.32 log2f64 F
+GLIBC_2.32 log2l F
+GLIBC_2.32 logb F
+GLIBC_2.32 logbf F
+GLIBC_2.32 logbf32 F
+GLIBC_2.32 logbf32x F
+GLIBC_2.32 logbf64 F
+GLIBC_2.32 logbl F
+GLIBC_2.32 logf F
+GLIBC_2.32 logf32 F
+GLIBC_2.32 logf32x F
+GLIBC_2.32 logf64 F
+GLIBC_2.32 logl F
+GLIBC_2.32 lrint F
+GLIBC_2.32 lrintf F
+GLIBC_2.32 lrintf32 F
+GLIBC_2.32 lrintf32x F
+GLIBC_2.32 lrintf64 F
+GLIBC_2.32 lrintl F
+GLIBC_2.32 lround F
+GLIBC_2.32 lroundf F
+GLIBC_2.32 lroundf32 F
+GLIBC_2.32 lroundf32x F
+GLIBC_2.32 lroundf64 F
+GLIBC_2.32 lroundl F
+GLIBC_2.32 modf F
+GLIBC_2.32 modff F
+GLIBC_2.32 modff32 F
+GLIBC_2.32 modff32x F
+GLIBC_2.32 modff64 F
+GLIBC_2.32 modfl F
+GLIBC_2.32 nan F
+GLIBC_2.32 nanf F
+GLIBC_2.32 nanf32 F
+GLIBC_2.32 nanf32x F
+GLIBC_2.32 nanf64 F
+GLIBC_2.32 nanl F
+GLIBC_2.32 nearbyint F
+GLIBC_2.32 nearbyintf F
+GLIBC_2.32 nearbyintf32 F
+GLIBC_2.32 nearbyintf32x F
+GLIBC_2.32 nearbyintf64 F
+GLIBC_2.32 nearbyintl F
+GLIBC_2.32 nextafter F
+GLIBC_2.32 nextafterf F
+GLIBC_2.32 nextafterf32 F
+GLIBC_2.32 nextafterf32x F
+GLIBC_2.32 nextafterf64 F
+GLIBC_2.32 nextafterl F
+GLIBC_2.32 nextdown F
+GLIBC_2.32 nextdownf F
+GLIBC_2.32 nextdownf32 F
+GLIBC_2.32 nextdownf32x F
+GLIBC_2.32 nextdownf64 F
+GLIBC_2.32 nextdownl F
+GLIBC_2.32 nexttoward F
+GLIBC_2.32 nexttowardf F
+GLIBC_2.32 nexttowardl F
+GLIBC_2.32 nextup F
+GLIBC_2.32 nextupf F
+GLIBC_2.32 nextupf32 F
+GLIBC_2.32 nextupf32x F
+GLIBC_2.32 nextupf64 F
+GLIBC_2.32 nextupl F
+GLIBC_2.32 pow F
+GLIBC_2.32 powf F
+GLIBC_2.32 powf32 F
+GLIBC_2.32 powf32x F
+GLIBC_2.32 powf64 F
+GLIBC_2.32 powl F
+GLIBC_2.32 remainder F
+GLIBC_2.32 remainderf F
+GLIBC_2.32 remainderf32 F
+GLIBC_2.32 remainderf32x F
+GLIBC_2.32 remainderf64 F
+GLIBC_2.32 remainderl F
+GLIBC_2.32 remquo F
+GLIBC_2.32 remquof F
+GLIBC_2.32 remquof32 F
+GLIBC_2.32 remquof32x F
+GLIBC_2.32 remquof64 F
+GLIBC_2.32 remquol F
+GLIBC_2.32 rint F
+GLIBC_2.32 rintf F
+GLIBC_2.32 rintf32 F
+GLIBC_2.32 rintf32x F
+GLIBC_2.32 rintf64 F
+GLIBC_2.32 rintl F
+GLIBC_2.32 round F
+GLIBC_2.32 roundeven F
+GLIBC_2.32 roundevenf F
+GLIBC_2.32 roundevenf32 F
+GLIBC_2.32 roundevenf32x F
+GLIBC_2.32 roundevenf64 F
+GLIBC_2.32 roundevenl F
+GLIBC_2.32 roundf F
+GLIBC_2.32 roundf32 F
+GLIBC_2.32 roundf32x F
+GLIBC_2.32 roundf64 F
+GLIBC_2.32 roundl F
+GLIBC_2.32 scalb F
+GLIBC_2.32 scalbf F
+GLIBC_2.32 scalbl F
+GLIBC_2.32 scalbln F
+GLIBC_2.32 scalblnf F
+GLIBC_2.32 scalblnf32 F
+GLIBC_2.32 scalblnf32x F
+GLIBC_2.32 scalblnf64 F
+GLIBC_2.32 scalblnl F
+GLIBC_2.32 scalbn F
+GLIBC_2.32 scalbnf F
+GLIBC_2.32 scalbnf32 F
+GLIBC_2.32 scalbnf32x F
+GLIBC_2.32 scalbnf64 F
+GLIBC_2.32 scalbnl F
+GLIBC_2.32 setpayload F
+GLIBC_2.32 setpayloadf F
+GLIBC_2.32 setpayloadf32 F
+GLIBC_2.32 setpayloadf32x F
+GLIBC_2.32 setpayloadf64 F
+GLIBC_2.32 setpayloadl F
+GLIBC_2.32 setpayloadsig F
+GLIBC_2.32 setpayloadsigf F
+GLIBC_2.32 setpayloadsigf32 F
+GLIBC_2.32 setpayloadsigf32x F
+GLIBC_2.32 setpayloadsigf64 F
+GLIBC_2.32 setpayloadsigl F
+GLIBC_2.32 signgam D 0x4
+GLIBC_2.32 significand F
+GLIBC_2.32 significandf F
+GLIBC_2.32 significandl F
+GLIBC_2.32 sin F
+GLIBC_2.32 sincos F
+GLIBC_2.32 sincosf F
+GLIBC_2.32 sincosf32 F
+GLIBC_2.32 sincosf32x F
+GLIBC_2.32 sincosf64 F
+GLIBC_2.32 sincosl F
+GLIBC_2.32 sinf F
+GLIBC_2.32 sinf32 F
+GLIBC_2.32 sinf32x F
+GLIBC_2.32 sinf64 F
+GLIBC_2.32 sinh F
+GLIBC_2.32 sinhf F
+GLIBC_2.32 sinhf32 F
+GLIBC_2.32 sinhf32x F
+GLIBC_2.32 sinhf64 F
+GLIBC_2.32 sinhl F
+GLIBC_2.32 sinl F
+GLIBC_2.32 sqrt F
+GLIBC_2.32 sqrtf F
+GLIBC_2.32 sqrtf32 F
+GLIBC_2.32 sqrtf32x F
+GLIBC_2.32 sqrtf64 F
+GLIBC_2.32 sqrtl F
+GLIBC_2.32 tan F
+GLIBC_2.32 tanf F
+GLIBC_2.32 tanf32 F
+GLIBC_2.32 tanf32x F
+GLIBC_2.32 tanf64 F
+GLIBC_2.32 tanh F
+GLIBC_2.32 tanhf F
+GLIBC_2.32 tanhf32 F
+GLIBC_2.32 tanhf32x F
+GLIBC_2.32 tanhf64 F
+GLIBC_2.32 tanhl F
+GLIBC_2.32 tanl F
+GLIBC_2.32 tgamma F
+GLIBC_2.32 tgammaf F
+GLIBC_2.32 tgammaf32 F
+GLIBC_2.32 tgammaf32x F
+GLIBC_2.32 tgammaf64 F
+GLIBC_2.32 tgammal F
+GLIBC_2.32 totalorder F
+GLIBC_2.32 totalorderf F
+GLIBC_2.32 totalorderf32 F
+GLIBC_2.32 totalorderf32x F
+GLIBC_2.32 totalorderf64 F
+GLIBC_2.32 totalorderl F
+GLIBC_2.32 totalordermag F
+GLIBC_2.32 totalordermagf F
+GLIBC_2.32 totalordermagf32 F
+GLIBC_2.32 totalordermagf32x F
+GLIBC_2.32 totalordermagf64 F
+GLIBC_2.32 totalordermagl F
+GLIBC_2.32 trunc F
+GLIBC_2.32 truncf F
+GLIBC_2.32 truncf32 F
+GLIBC_2.32 truncf32x F
+GLIBC_2.32 truncf64 F
+GLIBC_2.32 truncl F
+GLIBC_2.32 ufromfp F
+GLIBC_2.32 ufromfpf F
+GLIBC_2.32 ufromfpf32 F
+GLIBC_2.32 ufromfpf32x F
+GLIBC_2.32 ufromfpf64 F
+GLIBC_2.32 ufromfpl F
+GLIBC_2.32 ufromfpx F
+GLIBC_2.32 ufromfpxf F
+GLIBC_2.32 ufromfpxf32 F
+GLIBC_2.32 ufromfpxf32x F
+GLIBC_2.32 ufromfpxf64 F
+GLIBC_2.32 ufromfpxl F
+GLIBC_2.32 y0 F
+GLIBC_2.32 y0f F
+GLIBC_2.32 y0f32 F
+GLIBC_2.32 y0f32x F
+GLIBC_2.32 y0f64 F
+GLIBC_2.32 y0l F
+GLIBC_2.32 y1 F
+GLIBC_2.32 y1f F
+GLIBC_2.32 y1f32 F
+GLIBC_2.32 y1f32x F
+GLIBC_2.32 y1f64 F
+GLIBC_2.32 y1l F
+GLIBC_2.32 yn F
+GLIBC_2.32 ynf F
+GLIBC_2.32 ynf32 F
+GLIBC_2.32 ynf32x F
+GLIBC_2.32 ynf64 F
+GLIBC_2.32 ynl F
+GLIBC_2.31 totalorder F
+GLIBC_2.31 totalorderf F
+GLIBC_2.31 totalorderf32 F
+GLIBC_2.31 totalorderf32x F
+GLIBC_2.31 totalorderf64 F
+GLIBC_2.31 totalorderl F
+GLIBC_2.31 totalordermag F
+GLIBC_2.31 totalordermagf F
+GLIBC_2.31 totalordermagf32 F
+GLIBC_2.31 totalordermagf32x F
+GLIBC_2.31 totalordermagf64 F
+GLIBC_2.31 totalordermagl F
diff --git a/sysdeps/unix/sysv/linux/arc/libpthread.abilist b/sysdeps/unix/sysv/linux/arc/libpthread.abilist
new file mode 100644
index 000000000000..f1e9efd5343d
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libpthread.abilist
@@ -0,0 +1,227 @@
+GLIBC_2.32 _IO_flockfile F
+GLIBC_2.32 _IO_ftrylockfile F
+GLIBC_2.32 _IO_funlockfile F
+GLIBC_2.32 __close F
+GLIBC_2.32 __connect F
+GLIBC_2.32 __errno_location F
+GLIBC_2.32 __h_errno_location F
+GLIBC_2.32 __libc_allocate_rtsig F
+GLIBC_2.32 __libc_current_sigrtmax F
+GLIBC_2.32 __libc_current_sigrtmin F
+GLIBC_2.32 __lseek F
+GLIBC_2.32 __open F
+GLIBC_2.32 __open64 F
+GLIBC_2.32 __pread64 F
+GLIBC_2.32 __pthread_cleanup_routine F
+GLIBC_2.32 __pthread_getspecific F
+GLIBC_2.32 __pthread_key_create F
+GLIBC_2.32 __pthread_mutex_destroy F
+GLIBC_2.32 __pthread_mutex_init F
+GLIBC_2.32 __pthread_mutex_lock F
+GLIBC_2.32 __pthread_mutex_trylock F
+GLIBC_2.32 __pthread_mutex_unlock F
+GLIBC_2.32 __pthread_mutexattr_destroy F
+GLIBC_2.32 __pthread_mutexattr_init F
+GLIBC_2.32 __pthread_mutexattr_settype F
+GLIBC_2.32 __pthread_once F
+GLIBC_2.32 __pthread_register_cancel F
+GLIBC_2.32 __pthread_register_cancel_defer F
+GLIBC_2.32 __pthread_rwlock_destroy F
+GLIBC_2.32 __pthread_rwlock_init F
+GLIBC_2.32 __pthread_rwlock_rdlock F
+GLIBC_2.32 __pthread_rwlock_tryrdlock F
+GLIBC_2.32 __pthread_rwlock_trywrlock F
+GLIBC_2.32 __pthread_rwlock_unlock F
+GLIBC_2.32 __pthread_rwlock_wrlock F
+GLIBC_2.32 __pthread_setspecific F
+GLIBC_2.32 __pthread_unregister_cancel F
+GLIBC_2.32 __pthread_unregister_cancel_restore F
+GLIBC_2.32 __pthread_unwind_next F
+GLIBC_2.32 __pwrite64 F
+GLIBC_2.32 __read F
+GLIBC_2.32 __res_state F
+GLIBC_2.32 __send F
+GLIBC_2.32 __sigaction F
+GLIBC_2.32 __write F
+GLIBC_2.32 _pthread_cleanup_pop F
+GLIBC_2.32 _pthread_cleanup_pop_restore F
+GLIBC_2.32 _pthread_cleanup_push F
+GLIBC_2.32 _pthread_cleanup_push_defer F
+GLIBC_2.32 accept F
+GLIBC_2.32 call_once F
+GLIBC_2.32 close F
+GLIBC_2.32 cnd_broadcast F
+GLIBC_2.32 cnd_destroy F
+GLIBC_2.32 cnd_init F
+GLIBC_2.32 cnd_signal F
+GLIBC_2.32 cnd_timedwait F
+GLIBC_2.32 cnd_wait F
+GLIBC_2.32 connect F
+GLIBC_2.32 flockfile F
+GLIBC_2.32 fsync F
+GLIBC_2.32 ftrylockfile F
+GLIBC_2.32 funlockfile F
+GLIBC_2.32 lseek F
+GLIBC_2.32 lseek64 F
+GLIBC_2.32 msync F
+GLIBC_2.32 mtx_destroy F
+GLIBC_2.32 mtx_init F
+GLIBC_2.32 mtx_lock F
+GLIBC_2.32 mtx_timedlock F
+GLIBC_2.32 mtx_trylock F
+GLIBC_2.32 mtx_unlock F
+GLIBC_2.32 open F
+GLIBC_2.32 open64 F
+GLIBC_2.32 pause F
+GLIBC_2.32 pread F
+GLIBC_2.32 pread64 F
+GLIBC_2.32 pthread_attr_getaffinity_np F
+GLIBC_2.32 pthread_attr_getguardsize F
+GLIBC_2.32 pthread_attr_getschedpolicy F
+GLIBC_2.32 pthread_attr_getscope F
+GLIBC_2.32 pthread_attr_getstack F
+GLIBC_2.32 pthread_attr_getstackaddr F
+GLIBC_2.32 pthread_attr_getstacksize F
+GLIBC_2.32 pthread_attr_setaffinity_np F
+GLIBC_2.32 pthread_attr_setguardsize F
+GLIBC_2.32 pthread_attr_setschedpolicy F
+GLIBC_2.32 pthread_attr_setscope F
+GLIBC_2.32 pthread_attr_setstack F
+GLIBC_2.32 pthread_attr_setstackaddr F
+GLIBC_2.32 pthread_attr_setstacksize F
+GLIBC_2.32 pthread_barrier_destroy F
+GLIBC_2.32 pthread_barrier_init F
+GLIBC_2.32 pthread_barrier_wait F
+GLIBC_2.32 pthread_barrierattr_destroy F
+GLIBC_2.32 pthread_barrierattr_getpshared F
+GLIBC_2.32 pthread_barrierattr_init F
+GLIBC_2.32 pthread_barrierattr_setpshared F
+GLIBC_2.32 pthread_cancel F
+GLIBC_2.32 pthread_cond_broadcast F
+GLIBC_2.32 pthread_cond_clockwait F
+GLIBC_2.32 pthread_cond_destroy F
+GLIBC_2.32 pthread_cond_init F
+GLIBC_2.32 pthread_cond_signal F
+GLIBC_2.32 pthread_cond_timedwait F
+GLIBC_2.32 pthread_cond_wait F
+GLIBC_2.32 pthread_condattr_destroy F
+GLIBC_2.32 pthread_condattr_getclock F
+GLIBC_2.32 pthread_condattr_getpshared F
+GLIBC_2.32 pthread_condattr_init F
+GLIBC_2.32 pthread_condattr_setclock F
+GLIBC_2.32 pthread_condattr_setpshared F
+GLIBC_2.32 pthread_create F
+GLIBC_2.32 pthread_detach F
+GLIBC_2.32 pthread_exit F
+GLIBC_2.32 pthread_getaffinity_np F
+GLIBC_2.32 pthread_getattr_default_np F
+GLIBC_2.32 pthread_getattr_np F
+GLIBC_2.32 pthread_getconcurrency F
+GLIBC_2.32 pthread_getcpuclockid F
+GLIBC_2.32 pthread_getname_np F
+GLIBC_2.32 pthread_getschedparam F
+GLIBC_2.32 pthread_getspecific F
+GLIBC_2.32 pthread_join F
+GLIBC_2.32 pthread_key_create F
+GLIBC_2.32 pthread_key_delete F
+GLIBC_2.32 pthread_kill F
+GLIBC_2.32 pthread_kill_other_threads_np F
+GLIBC_2.32 pthread_mutex_clocklock F
+GLIBC_2.32 pthread_mutex_consistent F
+GLIBC_2.32 pthread_mutex_consistent_np F
+GLIBC_2.32 pthread_mutex_destroy F
+GLIBC_2.32 pthread_mutex_getprioceiling F
+GLIBC_2.32 pthread_mutex_init F
+GLIBC_2.32 pthread_mutex_lock F
+GLIBC_2.32 pthread_mutex_setprioceiling F
+GLIBC_2.32 pthread_mutex_timedlock F
+GLIBC_2.32 pthread_mutex_trylock F
+GLIBC_2.32 pthread_mutex_unlock F
+GLIBC_2.32 pthread_mutexattr_destroy F
+GLIBC_2.32 pthread_mutexattr_getkind_np F
+GLIBC_2.32 pthread_mutexattr_getprioceiling F
+GLIBC_2.32 pthread_mutexattr_getprotocol F
+GLIBC_2.32 pthread_mutexattr_getpshared F
+GLIBC_2.32 pthread_mutexattr_getrobust F
+GLIBC_2.32 pthread_mutexattr_getrobust_np F
+GLIBC_2.32 pthread_mutexattr_gettype F
+GLIBC_2.32 pthread_mutexattr_init F
+GLIBC_2.32 pthread_mutexattr_setkind_np F
+GLIBC_2.32 pthread_mutexattr_setprioceiling F
+GLIBC_2.32 pthread_mutexattr_setprotocol F
+GLIBC_2.32 pthread_mutexattr_setpshared F
+GLIBC_2.32 pthread_mutexattr_setrobust F
+GLIBC_2.32 pthread_mutexattr_setrobust_np F
+GLIBC_2.32 pthread_mutexattr_settype F
+GLIBC_2.32 pthread_once F
+GLIBC_2.32 pthread_rwlock_clockrdlock F
+GLIBC_2.32 pthread_rwlock_clockwrlock F
+GLIBC_2.32 pthread_rwlock_destroy F
+GLIBC_2.32 pthread_rwlock_init F
+GLIBC_2.32 pthread_rwlock_rdlock F
+GLIBC_2.32 pthread_rwlock_timedrdlock F
+GLIBC_2.32 pthread_rwlock_timedwrlock F
+GLIBC_2.32 pthread_rwlock_tryrdlock F
+GLIBC_2.32 pthread_rwlock_trywrlock F
+GLIBC_2.32 pthread_rwlock_unlock F
+GLIBC_2.32 pthread_rwlock_wrlock F
+GLIBC_2.32 pthread_rwlockattr_destroy F
+GLIBC_2.32 pthread_rwlockattr_getkind_np F
+GLIBC_2.32 pthread_rwlockattr_getpshared F
+GLIBC_2.32 pthread_rwlockattr_init F
+GLIBC_2.32 pthread_rwlockattr_setkind_np F
+GLIBC_2.32 pthread_rwlockattr_setpshared F
+GLIBC_2.32 pthread_setaffinity_np F
+GLIBC_2.32 pthread_setattr_default_np F
+GLIBC_2.32 pthread_setcancelstate F
+GLIBC_2.32 pthread_setcanceltype F
+GLIBC_2.32 pthread_setconcurrency F
+GLIBC_2.32 pthread_setname_np F
+GLIBC_2.32 pthread_setschedparam F
+GLIBC_2.32 pthread_setschedprio F
+GLIBC_2.32 pthread_setspecific F
+GLIBC_2.32 pthread_sigmask F
+GLIBC_2.32 pthread_sigqueue F
+GLIBC_2.32 pthread_spin_destroy F
+GLIBC_2.32 pthread_spin_init F
+GLIBC_2.32 pthread_spin_lock F
+GLIBC_2.32 pthread_spin_trylock F
+GLIBC_2.32 pthread_spin_unlock F
+GLIBC_2.32 pthread_testcancel F
+GLIBC_2.32 pthread_timedjoin_np F
+GLIBC_2.32 pthread_tryjoin_np F
+GLIBC_2.32 pthread_yield F
+GLIBC_2.32 pwrite F
+GLIBC_2.32 pwrite64 F
+GLIBC_2.32 raise F
+GLIBC_2.32 read F
+GLIBC_2.32 recv F
+GLIBC_2.32 recvfrom F
+GLIBC_2.32 recvmsg F
+GLIBC_2.32 sem_clockwait F
+GLIBC_2.32 sem_close F
+GLIBC_2.32 sem_destroy F
+GLIBC_2.32 sem_getvalue F
+GLIBC_2.32 sem_init F
+GLIBC_2.32 sem_open F
+GLIBC_2.32 sem_post F
+GLIBC_2.32 sem_timedwait F
+GLIBC_2.32 sem_trywait F
+GLIBC_2.32 sem_unlink F
+GLIBC_2.32 sem_wait F
+GLIBC_2.32 send F
+GLIBC_2.32 sendmsg F
+GLIBC_2.32 sendto F
+GLIBC_2.32 sigaction F
+GLIBC_2.32 sigwait F
+GLIBC_2.32 tcdrain F
+GLIBC_2.32 thrd_create F
+GLIBC_2.32 thrd_detach F
+GLIBC_2.32 thrd_exit F
+GLIBC_2.32 thrd_join F
+GLIBC_2.32 tss_create F
+GLIBC_2.32 tss_delete F
+GLIBC_2.32 tss_get F
+GLIBC_2.32 tss_set F
+GLIBC_2.32 write F
+GLIBC_2.31 pthread_clockjoin_np F
diff --git a/sysdeps/unix/sysv/linux/arc/libresolv.abilist b/sysdeps/unix/sysv/linux/arc/libresolv.abilist
new file mode 100644
index 000000000000..c5edf99ea942
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libresolv.abilist
@@ -0,0 +1,79 @@
+GLIBC_2.32 __b64_ntop F
+GLIBC_2.32 __b64_pton F
+GLIBC_2.32 __dn_comp F
+GLIBC_2.32 __dn_count_labels F
+GLIBC_2.32 __dn_expand F
+GLIBC_2.32 __dn_skipname F
+GLIBC_2.32 __fp_nquery F
+GLIBC_2.32 __fp_query F
+GLIBC_2.32 __fp_resstat F
+GLIBC_2.32 __hostalias F
+GLIBC_2.32 __loc_aton F
+GLIBC_2.32 __loc_ntoa F
+GLIBC_2.32 __p_cdname F
+GLIBC_2.32 __p_cdnname F
+GLIBC_2.32 __p_class F
+GLIBC_2.32 __p_class_syms D 0x54
+GLIBC_2.32 __p_fqname F
+GLIBC_2.32 __p_fqnname F
+GLIBC_2.32 __p_option F
+GLIBC_2.32 __p_query F
+GLIBC_2.32 __p_rcode F
+GLIBC_2.32 __p_time F
+GLIBC_2.32 __p_type F
+GLIBC_2.32 __p_type_syms D 0x228
+GLIBC_2.32 __putlong F
+GLIBC_2.32 __putshort F
+GLIBC_2.32 __res_close F
+GLIBC_2.32 __res_dnok F
+GLIBC_2.32 __res_hnok F
+GLIBC_2.32 __res_hostalias F
+GLIBC_2.32 __res_isourserver F
+GLIBC_2.32 __res_mailok F
+GLIBC_2.32 __res_mkquery F
+GLIBC_2.32 __res_nameinquery F
+GLIBC_2.32 __res_nmkquery F
+GLIBC_2.32 __res_nquery F
+GLIBC_2.32 __res_nquerydomain F
+GLIBC_2.32 __res_nsearch F
+GLIBC_2.32 __res_nsend F
+GLIBC_2.32 __res_ownok F
+GLIBC_2.32 __res_queriesmatch F
+GLIBC_2.32 __res_query F
+GLIBC_2.32 __res_querydomain F
+GLIBC_2.32 __res_search F
+GLIBC_2.32 __res_send F
+GLIBC_2.32 __sym_ntop F
+GLIBC_2.32 __sym_ntos F
+GLIBC_2.32 __sym_ston F
+GLIBC_2.32 _getlong F
+GLIBC_2.32 _getshort F
+GLIBC_2.32 inet_net_ntop F
+GLIBC_2.32 inet_net_pton F
+GLIBC_2.32 inet_neta F
+GLIBC_2.32 ns_datetosecs F
+GLIBC_2.32 ns_format_ttl F
+GLIBC_2.32 ns_get16 F
+GLIBC_2.32 ns_get32 F
+GLIBC_2.32 ns_initparse F
+GLIBC_2.32 ns_makecanon F
+GLIBC_2.32 ns_msg_getflag F
+GLIBC_2.32 ns_name_compress F
+GLIBC_2.32 ns_name_ntol F
+GLIBC_2.32 ns_name_ntop F
+GLIBC_2.32 ns_name_pack F
+GLIBC_2.32 ns_name_pton F
+GLIBC_2.32 ns_name_rollback F
+GLIBC_2.32 ns_name_skip F
+GLIBC_2.32 ns_name_uncompress F
+GLIBC_2.32 ns_name_unpack F
+GLIBC_2.32 ns_parse_ttl F
+GLIBC_2.32 ns_parserr F
+GLIBC_2.32 ns_put16 F
+GLIBC_2.32 ns_put32 F
+GLIBC_2.32 ns_samedomain F
+GLIBC_2.32 ns_samename F
+GLIBC_2.32 ns_skiprr F
+GLIBC_2.32 ns_sprintrr F
+GLIBC_2.32 ns_sprintrrf F
+GLIBC_2.32 ns_subdomain F
diff --git a/sysdeps/unix/sysv/linux/arc/librt.abilist b/sysdeps/unix/sysv/linux/arc/librt.abilist
new file mode 100644
index 000000000000..fda2b20c019a
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/librt.abilist
@@ -0,0 +1,35 @@
+GLIBC_2.32 __mq_open_2 F
+GLIBC_2.32 aio_cancel F
+GLIBC_2.32 aio_cancel64 F
+GLIBC_2.32 aio_error F
+GLIBC_2.32 aio_error64 F
+GLIBC_2.32 aio_fsync F
+GLIBC_2.32 aio_fsync64 F
+GLIBC_2.32 aio_init F
+GLIBC_2.32 aio_read F
+GLIBC_2.32 aio_read64 F
+GLIBC_2.32 aio_return F
+GLIBC_2.32 aio_return64 F
+GLIBC_2.32 aio_suspend F
+GLIBC_2.32 aio_suspend64 F
+GLIBC_2.32 aio_write F
+GLIBC_2.32 aio_write64 F
+GLIBC_2.32 lio_listio F
+GLIBC_2.32 lio_listio64 F
+GLIBC_2.32 mq_close F
+GLIBC_2.32 mq_getattr F
+GLIBC_2.32 mq_notify F
+GLIBC_2.32 mq_open F
+GLIBC_2.32 mq_receive F
+GLIBC_2.32 mq_send F
+GLIBC_2.32 mq_setattr F
+GLIBC_2.32 mq_timedreceive F
+GLIBC_2.32 mq_timedsend F
+GLIBC_2.32 mq_unlink F
+GLIBC_2.32 shm_open F
+GLIBC_2.32 shm_unlink F
+GLIBC_2.32 timer_create F
+GLIBC_2.32 timer_delete F
+GLIBC_2.32 timer_getoverrun F
+GLIBC_2.32 timer_gettime F
+GLIBC_2.32 timer_settime F
diff --git a/sysdeps/unix/sysv/linux/arc/libthread_db.abilist b/sysdeps/unix/sysv/linux/arc/libthread_db.abilist
new file mode 100644
index 000000000000..dcbc4a8fbef5
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libthread_db.abilist
@@ -0,0 +1,40 @@
+GLIBC_2.32 td_init F
+GLIBC_2.32 td_log F
+GLIBC_2.32 td_symbol_list F
+GLIBC_2.32 td_ta_clear_event F
+GLIBC_2.32 td_ta_delete F
+GLIBC_2.32 td_ta_enable_stats F
+GLIBC_2.32 td_ta_event_addr F
+GLIBC_2.32 td_ta_event_getmsg F
+GLIBC_2.32 td_ta_get_nthreads F
+GLIBC_2.32 td_ta_get_ph F
+GLIBC_2.32 td_ta_get_stats F
+GLIBC_2.32 td_ta_map_id2thr F
+GLIBC_2.32 td_ta_map_lwp2thr F
+GLIBC_2.32 td_ta_new F
+GLIBC_2.32 td_ta_reset_stats F
+GLIBC_2.32 td_ta_set_event F
+GLIBC_2.32 td_ta_setconcurrency F
+GLIBC_2.32 td_ta_thr_iter F
+GLIBC_2.32 td_ta_tsd_iter F
+GLIBC_2.32 td_thr_clear_event F
+GLIBC_2.32 td_thr_dbresume F
+GLIBC_2.32 td_thr_dbsuspend F
+GLIBC_2.32 td_thr_event_enable F
+GLIBC_2.32 td_thr_event_getmsg F
+GLIBC_2.32 td_thr_get_info F
+GLIBC_2.32 td_thr_getfpregs F
+GLIBC_2.32 td_thr_getgregs F
+GLIBC_2.32 td_thr_getxregs F
+GLIBC_2.32 td_thr_getxregsize F
+GLIBC_2.32 td_thr_set_event F
+GLIBC_2.32 td_thr_setfpregs F
+GLIBC_2.32 td_thr_setgregs F
+GLIBC_2.32 td_thr_setprio F
+GLIBC_2.32 td_thr_setsigpending F
+GLIBC_2.32 td_thr_setxregs F
+GLIBC_2.32 td_thr_sigsetmask F
+GLIBC_2.32 td_thr_tls_get_addr F
+GLIBC_2.32 td_thr_tlsbase F
+GLIBC_2.32 td_thr_tsd F
+GLIBC_2.32 td_thr_validate F
diff --git a/sysdeps/unix/sysv/linux/arc/libutil.abilist b/sysdeps/unix/sysv/linux/arc/libutil.abilist
new file mode 100644
index 000000000000..61f73bc34ef8
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/libutil.abilist
@@ -0,0 +1,6 @@
+GLIBC_2.32 forkpty F
+GLIBC_2.32 login F
+GLIBC_2.32 login_tty F
+GLIBC_2.32 logout F
+GLIBC_2.32 logwtmp F
+GLIBC_2.32 openpty F
diff --git a/sysdeps/unix/sysv/linux/arc/localplt.data b/sysdeps/unix/sysv/linux/arc/localplt.data
new file mode 100644
index 000000000000..e902fd0607a5
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/localplt.data
@@ -0,0 +1,16 @@
+libc.so: realloc
+libc.so: malloc
+libc.so: memalign
+libc.so: calloc
+libc.so: free
+# At -Os, a struct assignment in libgcc-static pulls this in
+libc.so: memcpy ?
+ld.so: malloc
+ld.so: calloc
+ld.so: realloc
+ld.so: free
+# The TLS-enabled version of these functions is interposed from libc.so.
+ld.so: _dl_signal_error
+ld.so: _dl_catch_error
+ld.so: _dl_signal_exception
+ld.so: _dl_catch_exception
diff --git a/sysdeps/unix/sysv/linux/arc/makecontext.c b/sysdeps/unix/sysv/linux/arc/makecontext.c
new file mode 100644
index 000000000000..dacf4289b025
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/makecontext.c
@@ -0,0 +1,75 @@
+/* Create new context for ARC.
+   Copyright (C) 2015-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sysdep.h>
+#include <stdarg.h>
+#include <stdint.h>
+#include <sys/ucontext.h>
+
+void
+__makecontext (ucontext_t *ucp, void (*func) (void), int argc, ...)
+{
+  extern void __startcontext (void) attribute_hidden;
+  unsigned long int sp, *r;
+  va_list vl;
+  int i, reg_args, stack_args;
+
+  sp = ((unsigned long int) ucp->uc_stack.ss_sp + ucp->uc_stack.ss_size) & ~7;
+
+  ucp->uc_mcontext.__scratch.__sp = sp;
+  ucp->uc_mcontext.__scratch.__fp = 0;
+
+  /* __startcontext is sort of trampoline to invoke @func
+     From setcontext() pov, the resume address is __startcontext,
+     set it up in BLINK place holder.  */
+
+  ucp->uc_mcontext.__scratch.__blink = (unsigned long int) &__startcontext;
+
+  /* __startcontext passed 2 types of args
+       - args to @func setup in canonical r0-r7
+       - @func itself in r9, and next function in r10.   */
+
+  ucp->uc_mcontext.__callee.__r13 = (unsigned long int) func;
+  ucp->uc_mcontext.__callee.__r14 = (unsigned long int) ucp->uc_link;
+
+  r = &ucp->uc_mcontext.__scratch.__r0;
+
+  va_start (vl, argc);
+
+  reg_args = argc > 8 ? 8 : argc;
+  for (i = 0; i < reg_args; i++) {
+      *r-- = va_arg(vl, unsigned long int);
+  }
+
+  stack_args = argc - reg_args;
+
+  if (__glibc_unlikely (stack_args > 0)) {
+
+    sp -=  stack_args * sizeof (unsigned long int);
+    ucp->uc_mcontext.__scratch.__sp = sp;
+    r = (unsigned long int *)sp;
+
+    for (i = 0; i < stack_args; i++) {
+        *r++ = va_arg(vl, unsigned long int);
+    }
+  }
+
+  va_end (vl);
+}
+
+weak_alias (__makecontext, makecontext)
diff --git a/sysdeps/unix/sysv/linux/arc/mmap_internal.h b/sysdeps/unix/sysv/linux/arc/mmap_internal.h
new file mode 100644
index 000000000000..19aa078dd45e
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/mmap_internal.h
@@ -0,0 +1,27 @@
+/* mmap - map files or devices into memory.  Linux/ARC version.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef MMAP_ARC_INTERNAL_H
+#define MMAP_ARC_INTERNAL_H
+
+/* 8K is default but determine the shift dynamically with getpagesize.  */
+#define MMAP2_PAGE_UNIT -1
+
+#include_next <mmap_internal.h>
+
+#endif
diff --git a/sysdeps/unix/sysv/linux/arc/pt-vfork.S b/sysdeps/unix/sysv/linux/arc/pt-vfork.S
new file mode 100644
index 000000000000..1cc893170070
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/pt-vfork.S
@@ -0,0 +1 @@
+/* Not needed.  */
diff --git a/sysdeps/unix/sysv/linux/arc/setcontext.S b/sysdeps/unix/sysv/linux/arc/setcontext.S
new file mode 100644
index 000000000000..45525e727998
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/setcontext.S
@@ -0,0 +1,92 @@
+/* Set current context for ARC.
+   Copyright (C) 2009-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include "ucontext-macros.h"
+
+/* int setcontext (const ucontext_t *ucp)
+     - Restores the machine context in @ucp and resumes execution
+       (doesn't return to caller).  */
+
+ENTRY (__setcontext)
+
+	mov  r9, r0	/* Stash @ucp across syscall.  */
+
+	/* rt_sigprocmask (SIG_SETMASK, &ucp->uc_sigmask, NULL, _NSIG8) */
+	mov  r3, _NSIG8
+	mov  r2, 0
+	add  r1, r0, UCONTEXT_SIGMASK
+	mov  r0, SIG_SETMASK
+	mov  r8, __NR_rt_sigprocmask
+	ARC_TRAP_INSN
+	brhi r0, -1024, .Lcall_syscall_err
+
+	/* Restore scratch/arg regs for makecontext() case.  */
+	LOAD_REG (r0,    r9, 22)
+	LOAD_REG (r1,    r9, 21)
+	LOAD_REG (r2,    r9, 20)
+	LOAD_REG (r3,    r9, 19)
+	LOAD_REG (r4,    r9, 18)
+	LOAD_REG (r5,    r9, 17)
+	LOAD_REG (r6,    r9, 16)
+	LOAD_REG (r7,    r9, 15)
+
+	/* Restore callee saved registers.  */
+	LOAD_REG (r13,   r9, 37)
+	LOAD_REG (r14,   r9, 36)
+	LOAD_REG (r15,   r9, 35)
+	LOAD_REG (r16,   r9, 34)
+	LOAD_REG (r17,   r9, 33)
+	LOAD_REG (r18,   r9, 32)
+	LOAD_REG (r19,   r9, 31)
+	LOAD_REG (r20,   r9, 30)
+	LOAD_REG (r21,   r9, 29)
+	LOAD_REG (r22,   r9, 28)
+	LOAD_REG (r23,   r9, 27)
+	LOAD_REG (r24,   r9, 26)
+	LOAD_REG (r25,   r9, 25)
+
+	LOAD_REG (blink, r9,  7)
+	LOAD_REG (fp,    r9,  8)
+	LOAD_REG (sp,    r9, 23)
+
+	j    [blink]
+
+PSEUDO_END (__setcontext)
+weak_alias (__setcontext, setcontext)
+
+
+/* Helper for activating makecontext() created context
+     - r13 has @func, r14 has uc_link.  */
+
+ENTRY (__startcontext)
+
+	.cfi_label .Ldummy
+	cfi_undefined (blink)
+
+        /* Call user @func, loaded in r13 by setcontext().  */
+        jl   [r13]
+
+        /* If uc_link (r14) call setcontext with that.  */
+        mov  r0, r14
+        breq r0, 0, 1f
+
+        bl   __setcontext
+1:
+        /* Exit with status 0.  */
+        b    HIDDEN_JUMPTARGET(exit)
+END (__startcontext)
diff --git a/sysdeps/unix/sysv/linux/arc/shlib-versions b/sysdeps/unix/sysv/linux/arc/shlib-versions
new file mode 100644
index 000000000000..a4b961583e95
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/shlib-versions
@@ -0,0 +1,2 @@
+DEFAULT                 GLIBC_2.32
+ld=ld-linux-arc.so.2
diff --git a/sysdeps/unix/sysv/linux/arc/sigaction.c b/sysdeps/unix/sysv/linux/arc/sigaction.c
new file mode 100644
index 000000000000..2613eb883fb1
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/sigaction.c
@@ -0,0 +1,31 @@
+/* ARC specific sigaction.
+   Copyright (C) 1997-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#define SA_RESTORER	0x04000000
+
+extern void __default_rt_sa_restorer (void);
+
+#define SET_SA_RESTORER(kact, act)				\
+ ({								\
+   (kact)->sa_restorer = __default_rt_sa_restorer;		\
+   (kact)->sa_flags |= SA_RESTORER;				\
+ })
+
+#define RESET_SA_RESTORER(act, kact)
+
+#include <sysdeps/unix/sysv/linux/sigaction.c>
diff --git a/sysdeps/unix/sysv/linux/arc/sigcontextinfo.h b/sysdeps/unix/sysv/linux/arc/sigcontextinfo.h
new file mode 100644
index 000000000000..551b4c9c1d2b
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/sigcontextinfo.h
@@ -0,0 +1,28 @@
+/* ARC definitions for signal handling calling conventions.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _SIGCONTEXTINFO_H
+#define _SIGCONTEXTINFO_H
+
+static inline uintptr_t
+sigcontext_get_pc (const ucontext_t *ctx)
+{
+  return ctx->uc_mcontext.__scratch.__ret;
+}
+
+#endif
diff --git a/sysdeps/unix/sysv/linux/arc/sigrestorer.S b/sysdeps/unix/sysv/linux/arc/sigrestorer.S
new file mode 100644
index 000000000000..cc3c1a0d09ff
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/sigrestorer.S
@@ -0,0 +1,29 @@
+/* Default sigreturn stub for ARC Linux.
+   Copyright (C) 2005-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sys/syscall.h>
+#include <sysdep.h>
+#include <tcb-offsets.h>
+
+/* Note the NOP has to be outside body.  */
+	nop
+ENTRY (__default_rt_sa_restorer)
+	mov r8, __NR_rt_sigreturn
+	ARC_TRAP_INSN
+	j_s     [blink]
+PSEUDO_END_NOERRNO (__default_rt_sa_restorer)
diff --git a/sysdeps/unix/sysv/linux/arc/swapcontext.S b/sysdeps/unix/sysv/linux/arc/swapcontext.S
new file mode 100644
index 000000000000..80ae73975af9
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/swapcontext.S
@@ -0,0 +1,92 @@
+/* Save and set current context for ARC.
+   Copyright (C) 2009-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include "ucontext-macros.h"
+
+/* int swapcontext (ucontext_t *oucp, const ucontext_t *ucp).  */
+
+ENTRY (__swapcontext)
+
+	/* Save context into @oucp pointed to by r0.  */
+
+	SAVE_REG (r13,   r0, 37)
+	SAVE_REG (r14,   r0, 36)
+	SAVE_REG (r15,   r0, 35)
+	SAVE_REG (r16,   r0, 34)
+	SAVE_REG (r17,   r0, 33)
+	SAVE_REG (r18,   r0, 32)
+	SAVE_REG (r19,   r0, 31)
+	SAVE_REG (r20,   r0, 30)
+	SAVE_REG (r21,   r0, 29)
+	SAVE_REG (r22,   r0, 28)
+	SAVE_REG (r23,   r0, 27)
+	SAVE_REG (r24,   r0, 26)
+	SAVE_REG (r25,   r0, 25)
+
+	SAVE_REG (blink, r0,  7)
+	SAVE_REG (fp,    r0,  8)
+	SAVE_REG (sp,    r0, 23)
+
+	/* Save 0 in r0 placeholder to return 0 when @oucp activated.  */
+	mov r9, 0
+	SAVE_REG (r9,    r0, 22)
+
+	/* Load context from @ucp.  */
+
+	mov r9, r1	/* Safekeep @ucp across syscall.  */
+
+	/* rt_sigprocmask (SIG_SETMASK, &ucp->uc_sigmask, &oucp->uc_sigmask, _NSIG8) */
+	mov r3, _NSIG8
+	add r2, r0, UCONTEXT_SIGMASK
+	add r1, r1, UCONTEXT_SIGMASK
+	mov r0, SIG_SETMASK
+	mov r8, __NR_rt_sigprocmask
+	ARC_TRAP_INSN
+	brhi r0, -1024, .Lcall_syscall_err
+
+	LOAD_REG (r0,    r9, 22)
+	LOAD_REG (r1,    r9, 21)
+	LOAD_REG (r2,    r9, 20)
+	LOAD_REG (r3,    r9, 19)
+	LOAD_REG (r4,    r9, 18)
+	LOAD_REG (r5,    r9, 17)
+	LOAD_REG (r6,    r9, 16)
+	LOAD_REG (r7,    r9, 15)
+
+	LOAD_REG (r13,   r9, 37)
+	LOAD_REG (r14,   r9, 36)
+	LOAD_REG (r15,   r9, 35)
+	LOAD_REG (r16,   r9, 34)
+	LOAD_REG (r17,   r9, 33)
+	LOAD_REG (r18,   r9, 32)
+	LOAD_REG (r19,   r9, 31)
+	LOAD_REG (r20,   r9, 30)
+	LOAD_REG (r21,   r9, 29)
+	LOAD_REG (r22,   r9, 28)
+	LOAD_REG (r23,   r9, 27)
+	LOAD_REG (r24,   r9, 26)
+	LOAD_REG (r25,   r9, 25)
+
+	LOAD_REG (blink, r9,  7)
+	LOAD_REG (fp,    r9,  8)
+	LOAD_REG (sp,    r9, 23)
+
+	j    [blink]
+
+PSEUDO_END (__swapcontext)
+weak_alias (__swapcontext, swapcontext)
diff --git a/sysdeps/unix/sysv/linux/arc/sys/cachectl.h b/sysdeps/unix/sysv/linux/arc/sys/cachectl.h
new file mode 100644
index 000000000000..1acb4018ae69
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/sys/cachectl.h
@@ -0,0 +1,36 @@
+/* cacheflush - flush contents of instruction and/or data cache.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _SYS_CACHECTL_H
+#define _SYS_CACHECTL_H 1
+
+#include <features.h>
+
+/* Get the kernel definition for the op bits.  */
+#include <asm/cachectl.h>
+
+__BEGIN_DECLS
+
+#ifdef __USE_MISC
+extern int cacheflush (void *__addr, const int __nbytes, const int __op) __THROW;
+#endif
+extern int _flush_cache (char *__addr, const int __nbytes, const int __op) __THROW;
+
+__END_DECLS
+
+#endif /* sys/cachectl.h */
diff --git a/sysdeps/unix/sysv/linux/arc/sys/ucontext.h b/sysdeps/unix/sysv/linux/arc/sys/ucontext.h
new file mode 100644
index 000000000000..ac4a32f76e55
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/sys/ucontext.h
@@ -0,0 +1,63 @@
+/* struct ucontext definition, ARC version.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+/* System V/ARC ABI compliant context switching support.  */
+
+#ifndef _SYS_UCONTEXT_H
+#define _SYS_UCONTEXT_H	1
+
+#include <features.h>
+
+#include <bits/types/sigset_t.h>
+#include <bits/types/stack_t.h>
+
+typedef struct
+  {
+    unsigned long int __pad;
+    struct {
+      unsigned long int __bta;
+      unsigned long int __lp_start, __lp_end, __lp_count;
+      unsigned long int __status32, __ret, __blink;
+      unsigned long int __fp, __gp;
+      unsigned long int __r12, __r11, __r10, __r9, __r8, __r7;
+      unsigned long int __r6, __r5, __r4, __r3, __r2, __r1, __r0;
+      unsigned long int __sp;
+    } __scratch;
+    unsigned long int __pad2;
+    struct {
+      unsigned long int __r25, __r24, __r23, __r22, __r21, __r20;
+      unsigned long int __r19, __r18, __r17, __r16, __r15, __r14, __r13;
+    } __callee;
+    unsigned long int __efa;
+    unsigned long int __stop_pc;
+    unsigned long int __r30, __r58, __r59;
+  } mcontext_t;
+
+/* Userlevel context.  */
+typedef struct ucontext_t
+  {
+    unsigned long int __uc_flags;
+    struct ucontext_t *uc_link;
+    stack_t uc_stack;
+    mcontext_t uc_mcontext;
+    sigset_t uc_sigmask;
+  } ucontext_t;
+
+#undef __ctx
+
+#endif /* sys/ucontext.h */
diff --git a/sysdeps/unix/sysv/linux/arc/sys/user.h b/sysdeps/unix/sysv/linux/arc/sys/user.h
new file mode 100644
index 000000000000..a556d2113d9c
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/sys/user.h
@@ -0,0 +1,31 @@
+/* ptrace register data format definitions.
+   Copyright (C) 1998-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _SYS_USER_H
+#define _SYS_USER_H	1
+
+/* Struct user_regs_struct is exported by kernel header
+   However apps like strace also expect a struct user, so it's better to
+   have a dummy implementation.  */
+#include <asm/ptrace.h>
+
+struct user {
+	int dummy;
+};
+
+#endif  /* sys/user.h */
diff --git a/sysdeps/unix/sysv/linux/arc/syscall.S b/sysdeps/unix/sysv/linux/arc/syscall.S
new file mode 100644
index 000000000000..d15ff2ed0cae
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/syscall.S
@@ -0,0 +1,38 @@
+/* syscall - indirect system call.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sysdep.h>
+
+ENTRY (syscall)
+	mov_s	r8, r0
+	mov_s	r0, r1
+	mov_s	r1, r2
+	mov_s	r2, r3
+	mov_s	r3, r4
+#ifdef __ARC700__
+	mov	r4, r5
+	mov	r5, r6
+#else
+	mov_s	r4, r5
+	mov_s	r5, r6
+#endif
+
+	ARC_TRAP_INSN
+	brhi	r0, -1024, .Lcall_syscall_err
+	j	[blink]
+PSEUDO_END (syscall)
diff --git a/sysdeps/unix/sysv/linux/arc/syscalls.list b/sysdeps/unix/sysv/linux/arc/syscalls.list
new file mode 100644
index 000000000000..d0ef5977ee06
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/syscalls.list
@@ -0,0 +1,3 @@
+# File name	Caller	Syscall name	Args	Strong name	Weak names
+
+cacheflush	-	cacheflush	i:pii	_flush_cache	cacheflush
diff --git a/sysdeps/unix/sysv/linux/arc/sysdep.c b/sysdeps/unix/sysv/linux/arc/sysdep.c
new file mode 100644
index 000000000000..a07fc035e6e5
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/sysdep.c
@@ -0,0 +1,33 @@
+/* ARC wrapper for setting errno.
+   Copyright (C) 1997-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sysdep.h>
+#include <errno.h>
+
+/* All syscall handler come here to avoid generated code bloat due to
+   GOT reference  to errno_location or it's equivalent.  */
+int
+__syscall_error(int err_no)
+{
+  __set_errno(-err_no);
+  return -1;
+}
+
+#if IS_IN (libc)
+hidden_def (__syscall_error)
+#endif
diff --git a/sysdeps/unix/sysv/linux/arc/sysdep.h b/sysdeps/unix/sysv/linux/arc/sysdep.h
new file mode 100644
index 000000000000..d799fab7574d
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/sysdep.h
@@ -0,0 +1,250 @@
+/* Assembler macros for ARC.
+   Copyright (C) 2000-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _LINUX_ARC_SYSDEP_H
+#define _LINUX_ARC_SYSDEP_H 1
+
+#include <sysdeps/arc/sysdep.h>
+#include <sysdeps/unix/sysv/linux/generic/sysdep.h>
+
+/* For RTLD_PRIVATE_ERRNO.  */
+#include <dl-sysdep.h>
+
+#include <tls.h>
+
+#undef SYS_ify
+#define SYS_ify(syscall_name)   __NR_##syscall_name
+
+#ifdef __ASSEMBLER__
+
+/* This is a "normal" system call stub: if there is an error,
+   it returns -1 and sets errno.  */
+
+# undef PSEUDO
+# define PSEUDO(name, syscall_name, args)			\
+  PSEUDO_NOERRNO(name, syscall_name, args)	ASM_LINE_SEP	\
+    brhi   r0, -1024, .Lcall_syscall_err	ASM_LINE_SEP
+
+# define ret	j  [blink]
+
+# undef PSEUDO_END
+# define PSEUDO_END(name)					\
+  SYSCALL_ERROR_HANDLER				ASM_LINE_SEP	\
+  END (name)
+
+/* --------- Helper for SYSCALL_NOERRNO -----------
+   This kind of system call stub never returns an error.
+   We return the return value register to the caller unexamined.  */
+
+# undef PSEUDO_NOERRNO
+# define PSEUDO_NOERRNO(name, syscall_name, args)		\
+  .text						ASM_LINE_SEP	\
+  ENTRY (name)					ASM_LINE_SEP	\
+    DO_CALL (syscall_name, args)		ASM_LINE_SEP	\
+
+/* Return the return value register unexamined. Since r0 is both
+   syscall return reg and function return reg, no work needed.  */
+# define ret_NOERRNO						\
+  j_s  [blink]		ASM_LINE_SEP
+
+# undef PSEUDO_END_NOERRNO
+# define PSEUDO_END_NOERRNO(name)				\
+  END (name)
+
+/* --------- Helper for SYSCALL_ERRVAL -----------
+   This kind of system call stub returns the errno code as its return
+   value, or zero for success.  We may massage the kernel's return value
+   to meet that ABI, but we never set errno here.  */
+
+# undef PSEUDO_ERRVAL
+# define PSEUDO_ERRVAL(name, syscall_name, args)		\
+  PSEUDO_NOERRNO(name, syscall_name, args)	ASM_LINE_SEP
+
+/* Don't set errno, return kernel error (in errno form) or zero.  */
+# define ret_ERRVAL						\
+  rsub   r0, r0, 0				ASM_LINE_SEP	\
+  ret_NOERRNO
+
+# undef PSEUDO_END_ERRVAL
+# define PSEUDO_END_ERRVAL(name)				\
+  END (name)
+
+
+/* To reduce the code footprint, we confine the actual errno access
+   to single place in __syscall_error().
+   This takes raw kernel error value, sets errno and returns -1.  */
+# if IS_IN (libc)
+#  define CALL_ERRNO_SETTER_C	bl     PLTJMP(HIDDEN_JUMPTARGET(__syscall_error))
+# else
+#  define CALL_ERRNO_SETTER_C	bl     PLTJMP(__syscall_error)
+# endif
+
+# define SYSCALL_ERROR_HANDLER					\
+.Lcall_syscall_err:				ASM_LINE_SEP	\
+    st.a   blink, [sp, -4]			ASM_LINE_SEP	\
+    cfi_adjust_cfa_offset (4)			ASM_LINE_SEP	\
+    cfi_rel_offset (blink, 0)			ASM_LINE_SEP	\
+    CALL_ERRNO_SETTER_C				ASM_LINE_SEP	\
+    ld.ab  blink, [sp, 4]			ASM_LINE_SEP	\
+    cfi_adjust_cfa_offset (-4)			ASM_LINE_SEP	\
+    cfi_restore (blink)				ASM_LINE_SEP	\
+    j      [blink]
+
+# define DO_CALL(syscall_name, args)				\
+    mov    r8, SYS_ify (syscall_name)		ASM_LINE_SEP	\
+    ARC_TRAP_INSN				ASM_LINE_SEP
+
+# define ARC_TRAP_INSN	trap_s 0
+
+#else  /* !__ASSEMBLER__ */
+
+# define SINGLE_THREAD_BY_GLOBAL		1
+
+/* In order to get __set_errno() definition in INLINE_SYSCALL.  */
+#include <errno.h>
+
+extern int __syscall_error (int);
+
+# if IS_IN (libc)
+hidden_proto (__syscall_error)
+#  define CALL_ERRNO_SETTER   "bl   __syscall_error    \n\t"
+# else
+#  define CALL_ERRNO_SETTER   "bl   __syscall_error@plt    \n\t"
+# endif
+
+
+/* Define a macro which expands into the inline wrapper code for a system
+   call.  */
+# undef INLINE_SYSCALL
+# define INLINE_SYSCALL(name, nr_args, args...)				\
+  ({									\
+    register int __res __asm__("r0");					\
+    __res = INTERNAL_SYSCALL_NCS (__NR_##name, , nr_args, args);	\
+    if (__builtin_expect (INTERNAL_SYSCALL_ERROR_P ((__res), ), 0))	\
+      {									\
+        asm volatile ("st.a blink, [sp, -4] \n\t"			\
+                      CALL_ERRNO_SETTER					\
+                      "ld.ab blink, [sp, 4] \n\t"			\
+                      :"+r" (__res)					\
+                      :							\
+                      :"r1","r2","r3","r4","r5","r6",			\
+                       "r7","r8","r9","r10","r11","r12");		\
+       }								\
+     __res;								\
+ })
+
+# undef INTERNAL_SYSCALL_DECL
+# define INTERNAL_SYSCALL_DECL(err) do { } while (0)
+
+# undef INTERNAL_SYSCALL_ERRNO
+# define INTERNAL_SYSCALL_ERRNO(val, err)    (-(val))
+
+/* -1 to -1023 are valid errno values.  */
+# undef INTERNAL_SYSCALL_ERROR_P
+# define INTERNAL_SYSCALL_ERROR_P(val, err)	\
+	((unsigned int) (val) > -1024U)
+
+# define ARC_TRAP_INSN	"trap_s 0	\n\t"
+
+# undef INTERNAL_SYSCALL_RAW
+# define INTERNAL_SYSCALL_RAW(name, err, nr_args, args...)	\
+  ({								\
+    /* Per ABI, r0 is 1st arg and return reg.  */		\
+    register int __ret __asm__("r0");				\
+    register int _sys_num __asm__("r8");			\
+								\
+    LOAD_ARGS_##nr_args (name, args)				\
+								\
+    __asm__ volatile (						\
+                      ARC_TRAP_INSN				\
+                      : "+r" (__ret)				\
+                      : "r"(_sys_num) ASM_ARGS_##nr_args	\
+                      : "memory");				\
+__ret;								\
+})
+
+/* Macros for setting up inline __asm__ input regs.  */
+# define ASM_ARGS_0
+# define ASM_ARGS_1	ASM_ARGS_0, "r" (__ret)
+# define ASM_ARGS_2	ASM_ARGS_1, "r" (_arg2)
+# define ASM_ARGS_3	ASM_ARGS_2, "r" (_arg3)
+# define ASM_ARGS_4	ASM_ARGS_3, "r" (_arg4)
+# define ASM_ARGS_5	ASM_ARGS_4, "r" (_arg5)
+# define ASM_ARGS_6	ASM_ARGS_5, "r" (_arg6)
+# define ASM_ARGS_7	ASM_ARGS_6, "r" (_arg7)
+
+/* Macros for converting sys-call wrapper args into sys call args.  */
+# define LOAD_ARGS_0(nm, arg)				\
+  _sys_num = (int) (nm);
+
+# define LOAD_ARGS_1(nm, arg1)				\
+  __ret = (int) (arg1);					\
+  LOAD_ARGS_0 (nm, arg1)
+
+/* Note that the use of _tmpX might look superflous, however it is needed
+   to ensure that register variables are not clobbered if arg happens to be
+   a function call itself. e.g. sched_setaffinity() calling getpid() for arg2
+   Also this specific order of recursive calling is important to segregate
+   the tmp args evaluation (function call case described above) and assigment
+   of register variables.  */
+
+# define LOAD_ARGS_2(nm, arg1, arg2)			\
+  int _tmp2 = (int) (arg2);				\
+  LOAD_ARGS_1 (nm, arg1)				\
+  register int _arg2 __asm__ ("r1") = _tmp2;
+
+# define LOAD_ARGS_3(nm, arg1, arg2, arg3)		\
+  int _tmp3 = (int) (arg3);				\
+  LOAD_ARGS_2 (nm, arg1, arg2)				\
+  register int _arg3 __asm__ ("r2") = _tmp3;
+
+#define LOAD_ARGS_4(nm, arg1, arg2, arg3, arg4)		\
+  int _tmp4 = (int) (arg4);				\
+  LOAD_ARGS_3 (nm, arg1, arg2, arg3)			\
+  register int _arg4 __asm__ ("r3") = _tmp4;
+
+# define LOAD_ARGS_5(nm, arg1, arg2, arg3, arg4, arg5)	\
+  int _tmp5 = (int) (arg5);				\
+  LOAD_ARGS_4 (nm, arg1, arg2, arg3, arg4)		\
+  register int _arg5 __asm__ ("r4") = _tmp5;
+
+# define LOAD_ARGS_6(nm,  arg1, arg2, arg3, arg4, arg5, arg6)\
+  int _tmp6 = (int) (arg6);				\
+  LOAD_ARGS_5 (nm, arg1, arg2, arg3, arg4, arg5)	\
+  register int _arg6 __asm__ ("r5") = _tmp6;
+
+# define LOAD_ARGS_7(nm, arg1, arg2, arg3, arg4, arg5, arg6, arg7)\
+  int _tmp7 = (int) (arg7);				\
+  LOAD_ARGS_6 (nm, arg1, arg2, arg3, arg4, arg5, arg6)	\
+  register int _arg7 __asm__ ("r6") = _tmp7;
+
+# undef INTERNAL_SYSCALL
+# define INTERNAL_SYSCALL(name, err, nr, args...) 	\
+  INTERNAL_SYSCALL_RAW(SYS_ify(name), err, nr, args)
+
+# undef INTERNAL_SYSCALL_NCS
+# define INTERNAL_SYSCALL_NCS(number, err, nr, args...) \
+  INTERNAL_SYSCALL_RAW(number, err, nr, args)
+
+/* Pointer mangling not yet supported.  */
+# define PTR_MANGLE(var) (void) (var)
+# define PTR_DEMANGLE(var) (void) (var)
+
+#endif /* !__ASSEMBLER__ */
+
+#endif /* linux/arc/sysdep.h */
diff --git a/sysdeps/unix/sysv/linux/arc/ucontext-macros.h b/sysdeps/unix/sysv/linux/arc/ucontext-macros.h
new file mode 100644
index 000000000000..4427be5dedd6
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/ucontext-macros.h
@@ -0,0 +1,29 @@
+/* Macros for ucontext routines, ARC version.
+   Copyright (C) 2017-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library.  If not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#ifndef _LINUX_ARC_UCONTEXT_MACROS_H
+#define _LINUX_ARC_UCONTEXT_MACROS_H
+
+#include <sysdep.h>
+
+#include "ucontext_i.h"
+
+#define SAVE_REG(reg, rbase, off)	st  reg, [rbase, UCONTEXT_MCONTEXT + off * 4]
+#define LOAD_REG(reg, rbase, off)	ld  reg, [rbase, UCONTEXT_MCONTEXT + off * 4]
+
+#endif
diff --git a/sysdeps/unix/sysv/linux/arc/ucontext_i.sym b/sysdeps/unix/sysv/linux/arc/ucontext_i.sym
new file mode 100644
index 000000000000..d84e92f9f543
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/ucontext_i.sym
@@ -0,0 +1,20 @@
+#include <inttypes.h>
+#include <signal.h>
+#include <stddef.h>
+#include <sys/ucontext.h>
+
+SIG_BLOCK
+SIG_SETMASK
+
+-- sizeof(sigset_t) expected by kernel: see comment in ARC sigaction.c for details
+_NSIG8				(_NSIG / 8)
+
+-- Offsets of the fields in the ucontext_t structure.
+#define ucontext(member)	offsetof (ucontext_t, member)
+
+UCONTEXT_FLAGS			ucontext (__uc_flags)
+UCONTEXT_LINK			ucontext (uc_link)
+UCONTEXT_STACK			ucontext (uc_stack)
+UCONTEXT_MCONTEXT		ucontext (uc_mcontext)
+UCONTEXT_SIGMASK		ucontext (uc_sigmask)
+UCONTEXT_SIZE			sizeof (ucontext_t)
diff --git a/sysdeps/unix/sysv/linux/arc/vfork.S b/sysdeps/unix/sysv/linux/arc/vfork.S
new file mode 100644
index 000000000000..ac1cce5258e0
--- /dev/null
+++ b/sysdeps/unix/sysv/linux/arc/vfork.S
@@ -0,0 +1,42 @@
+/* vfork for ARC Linux.
+   Copyright (C) 2005-2020 Free Software Foundation, Inc.
+   This file is part of the GNU C Library.
+
+   The GNU C Library is free software; you can redistribute it and/or
+   modify it under the terms of the GNU Lesser General Public
+   License as published by the Free Software Foundation; either
+   version 2.1 of the License, or (at your option) any later version.
+
+   The GNU C Library is distributed in the hope that it will be useful,
+   but WITHOUT ANY WARRANTY; without even the implied warranty of
+   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
+   Lesser General Public License for more details.
+
+   You should have received a copy of the GNU Lesser General Public
+   License along with the GNU C Library; if not, see
+   <https://www.gnu.org/licenses/>.  */
+
+#include <sys/syscall.h>
+#include <sysdep.h>
+#include <tcb-offsets.h>
+#define _SIGNAL_H
+#include <bits/signum.h>       /* For SIGCHLD */
+
+#define CLONE_VM		0x00000100
+#define CLONE_VFORK		0x00004000
+#define CLONE_FLAGS_FOR_VFORK	(CLONE_VM|CLONE_VFORK|SIGCHLD)
+
+ENTRY (__vfork)
+	mov	r0, CLONE_FLAGS_FOR_VFORK
+	mov_s	r1, sp
+	mov	r8, __NR_clone
+	ARC_TRAP_INSN
+
+	cmp	r0, 0
+	jge	[blink]	; child continues
+
+	b   __syscall_error
+PSEUDO_END (__vfork)
+libc_hidden_def (__vfork)
+
+weak_alias (__vfork, vfork)
diff --git a/sysdeps/unix/sysv/linux/syscall-names.list b/sysdeps/unix/sysv/linux/syscall-names.list
index 3d89814003a2..758b50164103 100644
--- a/sysdeps/unix/sysv/linux/syscall-names.list
+++ b/sysdeps/unix/sysv/linux/syscall-names.list
@@ -41,6 +41,9 @@ adjtimex
 afs_syscall
 alarm
 alloc_hugepages
+arc_gettls
+arc_settls
+arc_usr_cmpxchg
 arch_prctl
 arm_fadvise64_64
 arm_sync_file_range
EOF
	fi
}

add_automatic gmp
patch_gmp() {
	if test "$LIBC_NAME" = musl; then
		echo "patching gmp symbols for musl arch #788411"
		sed -i -r "s/([= ])(\!)?\<(${HOST_ARCH#musl-linux-})\>/\1\2\3 \2musl-linux-\3/" debian/libgmp10.symbols
		# musl does not implement GNU obstack
		sed -i -r 's/^ (.*_obstack_)/ (arch=!musl-linux-any !musleabihf-linux-any)\1/' debian/libgmp10.symbols
	fi
}

builddep_gnu_efi() {
	# binutils dependency needs cross translation
	$APT_GET install debhelper
}

add_automatic gnupg2

add_automatic gpm
patch_gpm() {
	if dpkg-architecture "-a$HOST_ARCH" -imusl-linux-any; then
		echo "patching gpm to support musl #813751"
		drop_privs patch -p1 <<'EOF'
--- a/src/lib/liblow.c
+++ a/src/lib/liblow.c
@@ -173,7 +173,7 @@
   /* Reincarnation. Prepare for another death early. */
   sigemptyset(&sa.sa_mask);
   sa.sa_handler = gpm_suspend_hook;
-  sa.sa_flags = SA_NOMASK;
+  sa.sa_flags = SA_NODEFER;
   sigaction (SIGTSTP, &sa, 0);
 
   /* Pop the gpm stack by closing the useless connection */
@@ -350,7 +350,7 @@
 
          /* if signal was originally ignored, job control is not supported */
          if (gpm_saved_suspend_hook.sa_handler != SIG_IGN) {
-            sa.sa_flags = SA_NOMASK;
+            sa.sa_flags = SA_NODEFER;
             sa.sa_handler = gpm_suspend_hook;
             sigaction(SIGTSTP, &sa, 0);
          }
--- a/src/prog/display-buttons.c
+++ b/src/prog/display-buttons.c
@@ -36,6 +36,7 @@
 #include <stdio.h>            /* printf()             */
 #include <time.h>             /* time()               */
 #include <errno.h>            /* errno                */
+#include <sys/select.h>       /* fd_set, FD_ZERO      */
 #include <gpm.h>              /* gpm information      */
 
 /* display resulting data */
--- a/src/prog/display-coords.c
+++ b/src/prog/display-coords.c
@@ -37,6 +37,7 @@
 #include <stdio.h>            /* printf()             */
 #include <time.h>             /* time()               */
 #include <errno.h>            /* errno                */
+#include <sys/select.h>       /* fd_set, FD_ZERO      */
 #include <gpm.h>              /* gpm information      */
 
 /* display resulting data */
--- a/src/prog/gpm-root.y
+++ b/src/prog/gpm-root.y
@@ -1197,6 +1197,9 @@
    /* reap your zombies */
    childaction.sa_handler=reap_children;
    sigemptyset(&childaction.sa_mask);
+#ifndef SA_INTERRUPT
+#define SA_INTERRUPT 0
+#endif
    childaction.sa_flags=SA_INTERRUPT; /* need to break the select() call */
    sigaction(SIGCHLD,&childaction,NULL);
 
--- a/contrib/control/gpm_has_mouse_control.c
+++ a/contrib/control/gpm_has_mouse_control.c
@@ -1,4 +1,4 @@
-#include <sys/fcntl.h>
+#include <fcntl.h>
 #include <sys/kd.h>
 #include <stdio.h>
 #include <stdlib.h>
EOF
	fi
}

add_automatic grep
add_automatic groff
add_automatic guile-2.2
add_automatic guile-3.0

add_automatic gzip
buildenv_gzip() {
	if test "$LIBC_NAME" = musl; then
		# this avoids replacing fseeko with a variant that is broken
		echo gl_cv_func_fflush_stdin exported
		export gl_cv_func_fflush_stdin=yes
	fi
	if test "$(dpkg-architecture "-a$1" -qDEB_HOST_ARCH_BITS)" = 32; then
		# If touch works with large timestamps (e.g. on amd64),
		# gzip fails instead of warning about 32bit time_t.
		echo "TIME_T_32_BIT_OK=yes exported"
		export TIME_T_32_BIT_OK=yes
	fi
}

add_automatic hostname
add_automatic icu
add_automatic isl
add_automatic isl-0.18
add_automatic jansson
add_automatic jemalloc
add_automatic keyutils
add_automatic kmod

add_automatic krb5
buildenv_krb5() {
	export krb5_cv_attr_constructor_destructor=yes,yes
	export ac_cv_func_regcomp=yes
	export ac_cv_printf_positional=yes
}

add_automatic libassuan
add_automatic libatomic-ops
add_automatic libbsd
add_automatic libcap2
add_automatic libdebian-installer
add_automatic libev
add_automatic libevent
add_automatic libffi
add_automatic libgc

add_automatic libgcrypt20
buildenv_libgcrypt20() {
	export ac_cv_sys_symbol_underscore=no
}

add_automatic libgpg-error
add_automatic libice
add_automatic libidn
add_automatic libidn2
add_automatic libksba
add_automatic libmd
add_automatic libnsl
add_automatic libonig
add_automatic libpipeline
add_automatic libpng1.6

patch_libprelude() {
	echo "removing the unsatisfiable g++ build dependency"
	drop_privs sed -i -e '/^\s\+g++/d' debian/control
}
buildenv_libprelude() {
	case $(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_SYSTEM) in *gnu*)
		echo "glibc does not return NULL for malloc(0)"
		export ac_cv_func_malloc_0_nonnull=yes
	;; esac
}

add_automatic libpsl
add_automatic libpthread-stubs
add_automatic libsepol
add_automatic libsm
add_automatic libsodium
add_automatic libssh2
add_automatic libsystemd-dummy
add_automatic libtasn1-6
add_automatic libtextwrap
add_automatic libtirpc

builddep_libtool() {
	assert_built "zlib"
	test "$1" = "$HOST_ARCH"
	# gfortran dependency needs cross-translation
	# gnulib dependency lacks M-A:foreign
	apt_get_install debhelper file "gfortran-$GCC_VER$HOST_ARCH_SUFFIX" automake autoconf autotools-dev help2man texinfo "zlib1g-dev:$HOST_ARCH" gnulib
}

add_automatic libunistring
buildenv_libunistring() {
	if dpkg-architecture "-a$HOST_ARCH" -ignu-any-any; then
		echo "glibc does not prefer rwlock writers to readers"
		export gl_cv_pthread_rwlock_rdlock_prefer_writer=no
	fi
}

add_automatic libusb
add_automatic libusb-1.0
add_automatic libverto

add_automatic libx11
buildenv_libx11() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libxau
add_automatic libxaw
add_automatic libxcb
add_automatic libxdmcp

add_automatic libxext
buildenv_libxext() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libxmu
add_automatic libxpm

add_automatic libxrender
buildenv_libxrender() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libxss
buildenv_libxss() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libxt
buildenv_libxt() {
	export xorg_cv_malloc0_returns_null=no
}

add_automatic libzstd

patch_linux() {
	local kernel_arch comment
	kernel_arch=
	comment="just building headers yet"
	case "$HOST_ARCH" in
		arc|ia64|nios2)
			kernel_arch=$HOST_ARCH
		;;
		mipsr6|mipsr6el|mipsn32r6|mipsn32r6el|mips64r6|mips64r6el)
			kernel_arch=defines-only
		;;
		powerpcel) kernel_arch=powerpc; ;;
		riscv64) kernel_arch=riscv; ;;
		*-linux-*)
			if ! test -d "debian/config/$HOST_ARCH"; then
				kernel_arch=$(sed 's/^kernel-arch: //;t;d' < "debian/config/${HOST_ARCH#*-linux-}/defines")
				comment="$HOST_ARCH must be part of a multiarch installation with a ${HOST_ARCH#*-linux-*} kernel"
			fi
		;;
	esac
	if test -n "$kernel_arch"; then
		if test "$kernel_arch" != defines-only; then
			echo "patching linux for $HOST_ARCH with kernel-arch $kernel_arch"
			drop_privs mkdir -p "debian/config/$HOST_ARCH"
			drop_privs tee "debian/config/$HOST_ARCH/defines" >/dev/null <<EOF
[base]
kernel-arch: $kernel_arch
featuresets:
# empty; $comment
EOF
		else
			echo "patching linux to enable $HOST_ARCH"
		fi
		drop_privs sed -i -e "/^arches:/a\\ $HOST_ARCH" debian/config/defines
		apt_get_install kernel-wedge
		drop_privs ./debian/rules debian/rules.gen || : # intentionally exits 1 to avoid being called automatically. we are doing it wrong
	fi
}

add_automatic lz4
add_automatic make-dfsg
add_automatic man-db
add_automatic mawk
add_automatic mpclib3
add_automatic mpdecimal
add_automatic mpfr4

builddep_ncurses() {
	if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux; then
		assert_built gpm
		$APT_GET install "libgpm-dev:$1"
	fi
	# g++-multilib dependency unsatisfiable
	apt_get_install debhelper pkg-config autoconf-dickey
	case "$ENABLE_MULTILIB:$HOST_ARCH" in
		yes:amd64|yes:i386|yes:powerpc|yes:ppc64|yes:s390|yes:sparc)
			test "$1" = "$HOST_ARCH"
			$APT_GET install "g++-$GCC_VER-multilib$HOST_ARCH_SUFFIX"
			# the unversioned gcc-multilib$HOST_ARCH_SUFFIX should contain the following link
			ln -sf "`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_MULTIARCH`/asm" /usr/include/asm
		;;
	esac
}

add_automatic nettle
add_automatic nghttp2
add_automatic npth
add_automatic nspr

add_automatic nss
patch_nss() {
	if dpkg-architecture "-a$HOST_ARCH" -iany-ppc64el; then
		echo "fix FTCBFS for ppc64el #948523"
		drop_privs patch -p1 <<'EOF'
--- a/debian/rules
+++ b/debian/rules
@@ -40,7 +40,8 @@
 ifeq ($(origin RANLIB),default)
 TOOLCHAIN += RANLIB=$(DEB_HOST_GNU_TYPE)-ranlib
 endif
-TOOLCHAIN += OS_TEST=$(DEB_HOST_GNU_CPU)
+OS_TYPE_map_powerpc64le = ppc64le
+TOOLCHAIN += OS_TEST=$(or $(OS_TYPE_map_$(DEB_HOST_GNU_CPU)),$(DEB_HOST_GNU_CPU))
 TOOLCHAIN += KERNEL=$(DEB_HOST_ARCH_OS)
 endif

EOF
	fi
	echo "work around FTBFS #951644"
	drop_privs patch -p1 <<'EOF'
--- a/debian/rules
+++ b/debian/rules
@@ -110,6 +110,7 @@
 		NSPR_LIB_DIR=/usr/lib/$(DEB_HOST_MULTIARCH) \
 		BUILD_OPT=1 \
 		NS_USE_GCC=1 \
+		NSS_ENABLE_WERROR=0 \
 		OPTIMIZER="$(CFLAGS) $(CPPFLAGS)" \
 		LDFLAGS='$(LDFLAGS) $$(ARCHFLAG) $$(ZDEFS_FLAG)' \
 		DSO_LDOPTS='-shared $$(LDFLAGS)' \
EOF
}

buildenv_openldap() {
	export ol_cv_pthread_select_yields=yes
	export ac_cv_func_memcmp_working=yes
}

add_automatic openssl
add_automatic openssl1.0
add_automatic p11-kit
add_automatic patch
add_automatic pcre2
add_automatic pcre3
add_automatic popt

builddep_readline() {
	assert_built "ncurses"
	# gcc-multilib dependency unsatisfiable
	$APT_GET install debhelper "libtinfo-dev:$1" "libncursesw5-dev:$1" mawk texinfo autotools-dev
	case "$ENABLE_MULTILIB:$HOST_ARCH" in
		yes:amd64|yes:ppc64)
			test "$1" = "$HOST_ARCH"
			$APT_GET install "gcc-$GCC_VER-multilib$HOST_ARCH_SUFFIX" "lib32tinfo-dev:$1" "lib32ncursesw5-dev:$1"
			# the unversioned gcc-multilib$HOST_ARCH_SUFFIX should contain the following link
			ln -sf "`dpkg-architecture -a$1 -qDEB_HOST_MULTIARCH`/asm" /usr/include/asm
		;;
		yes:i386|yes:powerpc|yes:sparc|yes:s390)
			test "$1" = "$HOST_ARCH"
			$APT_GET install "gcc-$GCC_VER-multilib$HOST_ARCH_SUFFIX" "lib64ncurses5-dev:$1"
			# the unversioned gcc-multilib$HOST_ARCH_SUFFIX should contain the following link
			ln -sf "`dpkg-architecture -a$1 -qDEB_HOST_MULTIARCH`/asm" /usr/include/asm
		;;
	esac
}
patch_readline() {
	echo "patching readline to support nobiarch profile #737955"
	drop_privs patch -p1 <<'EOF'
--- a/debian/control
+++ b/debian/control
@@ -5,9 +5,9 @@
 Standards-Version: 4.5.0
 Build-Depends: debhelper (>= 11),
   libncurses-dev,
-  lib32ncurses-dev [amd64 ppc64], lib64ncurses-dev [i386 powerpc sparc s390],
+  lib32ncurses-dev [amd64 ppc64] <!nobiarch>, lib64ncurses-dev [i386 powerpc sparc s390] <!nobiarch>,
   mawk | awk, texinfo,
-  gcc-multilib [amd64 i386 kfreebsd-amd64 powerpc ppc64 s390 sparc]
+  gcc-multilib [amd64 i386 kfreebsd-amd64 powerpc ppc64 s390 sparc] <!nobiarch>

 Package: libreadline8
 Architecture: any
@@ -27,6 +27,7 @@
 Architecture: i386 powerpc s390 sparc
 Depends: readline-common, ${shlibs:Depends}, ${misc:Depends}
 Section: libs
+Build-Profiles: <!nobiarch>
 Description: GNU readline and history libraries, run-time libraries (64-bit)
  The GNU readline library aids in the consistency of user interface
  across discrete programs that need to provide a command line
@@ -75,6 +76,7 @@
 Conflicts: lib64readline6-dev, lib64readline-gplv2-dev
 Provides: lib64readline6-dev
 Section: libdevel
+Build-Profiles: <!nobiarch>
 Description: GNU readline and history libraries, development files (64-bit)
  The GNU readline library aids in the consistency of user interface
  across discrete programs that need to provide a command line
@@ -101,6 +103,7 @@
 Architecture: amd64 ppc64
 Depends: readline-common, ${shlibs:Depends}, ${misc:Depends}
 Section: libs
+Build-Profiles: <!nobiarch>
 Description: GNU readline and history libraries, run-time libraries (32-bit)
  The GNU readline library aids in the consistency of user interface
  across discrete programs that need to provide a command line
@@ -115,6 +118,7 @@
 Conflicts: lib32readline6-dev, lib32readline-gplv2-dev
 Provides: lib32readline6-dev
 Section: libdevel
+Build-Profiles: <!nobiarch>
 Description: GNU readline and history libraries, development files (32-bit)
  The GNU readline library aids in the consistency of user interface
  across discrete programs that need to provide a command line
--- a/debian/rules
+++ b/debian/rules
@@ -57,6 +57,11 @@
   endif
 endif

+ifneq (,$(filter nobiarch,$(DEB_BUILD_PROFILES)))
+build32 =
+build64 =
+endif
+
 unexport CPPFLAGS CFLAGS LDFLAGS

 CFLAGS := $(shell dpkg-buildflags --get CFLAGS)
EOF
}

add_automatic rtmpdump
add_automatic sed
add_automatic shadow
add_automatic slang2
add_automatic spdylay
add_automatic sqlite3
add_automatic sysvinit

add_automatic tar
buildenv_tar() {
	case $(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_SYSTEM) in *gnu*)
		echo "struct dirent contains working d_ino on glibc systems"
		export gl_cv_struct_dirent_d_ino=yes
	;; esac
	if ! dpkg-architecture "-a$HOST_ARCH" -ilinux-any; then
		echo "forcing broken posix acl check to fail on non-linux #850668"
		export gl_cv_getxattr_with_posix_acls=no
	fi
}

add_automatic tcl8.6
buildenv_tcl8_6() {
	export tcl_cv_strtod_buggy=ok
	export tcl_cv_strtoul_unbroken=ok
}

add_automatic tcltk-defaults
add_automatic tcp-wrappers

add_automatic tk8.6
buildenv_tk8_6() {
	export tcl_cv_strtod_buggy=ok
}

add_automatic uchardet
add_automatic ustr

buildenv_util_linux() {
	export scanf_cv_type_modifier=ms
}

add_automatic xft
add_automatic xxhash
add_automatic xz-utils

builddep_zlib() {
	# gcc-multilib dependency unsatisfiable
	$APT_GET install debhelper binutils dpkg-dev
}

# choosing libatomic1 arbitrarily here, cause it never bumped soname
BUILD_GCC_MULTIARCH_VER=`apt-cache show --no-all-versions libatomic1 | sed 's/^Source: gcc-\([0-9.]*\)$/\1/;t;d'`
if test "$GCC_VER" != "$BUILD_GCC_MULTIARCH_VER"; then
	echo "host gcc version ($GCC_VER) and build gcc version ($BUILD_GCC_MULTIARCH_VER) mismatch. need different build gcc"
if dpkg --compare-versions "$GCC_VER" gt "$BUILD_GCC_MULTIARCH_VER"; then
	echo "deb [ arch=$(dpkg --print-architecture) ] $MIRROR experimental main" > /etc/apt/sources.list.d/tmp-experimental.list
	$APT_GET update
	$APT_GET -t experimental install g++ g++-$GCC_VER
	test "$GCC_VER" = 11 && $APT_GET -t experimental install binutils
	rm -f /etc/apt/sources.list.d/tmp-experimental.list
	$APT_GET update
elif test -f "$REPODIR/stamps/gcc_0"; then
	echo "skipping rebuild of build gcc"
	$APT_GET --force-yes dist-upgrade # downgrade!
else
	$APT_GET build-dep --arch-only gcc-$GCC_VER
	# dependencies for common libs no longer declared
	$APT_GET install doxygen graphviz ghostscript texlive-latex-base xsltproc docbook-xsl-ns
	cross_build_setup "gcc-$GCC_VER" gcc0
	(
		export gcc_cv_libc_provides_ssp=yes
		nolang=$(set_add "${GCC_NOLANG:-}" biarch)
		export DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS nostrap nolang=$(join_words , $nolang)"
		drop_privs_exec dpkg-buildpackage -B -uc -us
	)
	cd ..
	ls -l
	reprepro include rebootstrap-native ./*.changes
	drop_privs rm -fv ./*-plugin-dev_*.deb ./*-dbg_*.deb
	dpkg -i *.deb
	touch "$REPODIR/stamps/gcc_0"
	cd ..
	drop_privs rm -Rf gcc0
fi
progress_mark "build compiler complete"
else
echo "host gcc version and build gcc version match. good for multiarch"
fi

if test -f "$REPODIR/stamps/cross-binutils"; then
	echo "skipping rebuild of binutils-target"
else
	cross_build_setup binutils
	check_binNMU
	apt_get_build_dep --arch-only -Pnocheck ./
	drop_privs TARGET=$HOST_ARCH dpkg-buildpackage -B -Pnocheck --target=stamps/control
	drop_privs TARGET=$HOST_ARCH dpkg-buildpackage -B -uc -us -Pnocheck
	cd ..
	ls -l
	pickup_packages *.changes
	$APT_GET install binutils$HOST_ARCH_SUFFIX
	assembler="`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_GNU_TYPE`-as"
	if ! which "$assembler"; then echo "$assembler missing in binutils package"; exit 1; fi
	if ! drop_privs "$assembler" -o test.o /dev/null; then echo "binutils fail to execute"; exit 1; fi
	if ! test -f test.o; then echo "binutils fail to create object"; exit 1; fi
	check_arch test.o "$HOST_ARCH"
	touch "$REPODIR/stamps/cross-binutils"
	cd ..
	drop_privs rm -Rf binutils
fi
progress_mark "cross binutils"

if test "$HOST_ARCH" = hppa && ! test -f "$REPODIR/stamps/cross-binutils-hppa64"; then
	cross_build_setup binutils binutils-hppa64
	check_binNMU
	apt_get_build_dep --arch-only -Pnocheck ./
	drop_privs TARGET=hppa64-linux-gnu dpkg-buildpackage -B -Pnocheck --target=stamps/control
	drop_privs TARGET=hppa64-linux-gnu dpkg-buildpackage -B -uc -us -Pnocheck
	cd ..
	ls -l
	pickup_additional_packages binutils-hppa64-linux-gnu_*.deb
	$APT_GET install binutils-hppa64-linux-gnu
	if ! which hppa64-linux-gnu-as; then echo "hppa64-linux-gnu-as missing in binutils package"; exit 1; fi
	if ! drop_privs hppa64-linux-gnu-as -o test.o /dev/null; then echo "binutils-hppa64 fail to execute"; exit 1; fi
	if ! test -f test.o; then echo "binutils-hppa64 fail to create object"; exit 1; fi
	check_arch test.o hppa64
	touch "$REPODIR/stamps/cross-binutils-hppa64"
	cd ..
	drop_privs rm -Rf binutils-hppa64-linux-gnu
	progress_mark "cross binutils-hppa64"
fi

if test "`dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS`" = "linux"; then
if test -f "$REPODIR/stamps/linux_1"; then
	echo "skipping rebuild of linux-libc-dev"
else
	cross_build_setup linux
	check_binNMU
	if dpkg-architecture -ilinux-any && test "$(dpkg-query -W -f '${Version}' "linux-libc-dev:$(dpkg --print-architecture)")" != "$(dpkg-parsechangelog -SVersion)"; then
		echo "rebootstrap-warning: working around linux-libc-dev m-a:same skew"
		apt_get_build_dep --arch-only -Pstage1 ./
		drop_privs KBUILD_VERBOSE=1 dpkg-buildpackage -B -Pstage1 -uc -us
	fi
	apt_get_build_dep --arch-only "-a$HOST_ARCH" -Pstage1 ./
	drop_privs KBUILD_VERBOSE=1 dpkg-buildpackage -B "-a$HOST_ARCH" -Pstage1 -uc -us
	cd ..
	ls -l
	if test "$ENABLE_MULTIARCH_GCC" != yes; then
		drop_privs dpkg-cross -M -a "$HOST_ARCH" -b ./*"_$HOST_ARCH.deb"
	fi
	pickup_packages *.deb
	touch "$REPODIR/stamps/linux_1"
	compare_native ./*.deb
	cd ..
	drop_privs rm -Rf linux
fi
progress_mark "linux-libc-dev cross build"
fi

if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = hurd; then
if test -f "$REPODIR/stamps/gnumach_1"; then
	echo "skipping rebuild of gnumach stage1"
else
	cross_build_setup gnumach gnumach_1
	apt_get_build_dep "-a$HOST_ARCH" --arch-only -Pstage1 ./
	drop_privs dpkg-buildpackage -B "-a$HOST_ARCH" -Pstage1 -uc -us
	cd ..
	pickup_packages ./*.deb
	touch "$REPODIR/stamps/gnumach_1"
	cd ..
	drop_privs rm -Rf gnumach_1
fi
progress_mark "gnumach stage1 cross build"
fi

test "$GCC_VER" = 10 && GCC_AUTOCONF=autoconf2.64 || GCC_AUTOCONF=autoconf2.69
if test -f "$REPODIR/stamps/gcc_1"; then
	echo "skipping rebuild of gcc stage1"
else
	apt_get_install debhelper gawk patchutils bison flex lsb-release quilt libtool $GCC_AUTOCONF zlib1g-dev libmpc-dev libmpfr-dev libgmp-dev autogen systemtap-sdt-dev sharutils "binutils$HOST_ARCH_SUFFIX" time
	if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux; then
		if test "$ENABLE_MULTIARCH_GCC" = yes; then
			apt_get_install "linux-libc-dev:$HOST_ARCH"
		else
			apt_get_install "linux-libc-dev-${HOST_ARCH}-cross"
		fi
	fi
	if test "$HOST_ARCH" = hppa; then
		$APT_GET install binutils-hppa64-linux-gnu
	fi
	cross_build_setup "gcc-$GCC_VER" gcc1
	check_binNMU
	dpkg-checkbuilddeps || : # tell unmet build depends
	echo "$HOST_ARCH" > debian/target
	(
		nolang=${GCC_NOLANG:-}
		test "$ENABLE_MULTILIB" = yes || nolang=$(set_add "$nolang" biarch)
		export DEB_STAGE=stage1
		export DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS${nolang:+ nolang=$(join_words , $nolang)}"
		drop_privs dpkg-buildpackage -d -T control
		dpkg-checkbuilddeps || : # tell unmet build depends again after rewriting control
		drop_privs_exec dpkg-buildpackage -d -b -uc -us
	)
	cd ..
	ls -l
	pickup_packages *.changes
	apt_get_remove gcc-multilib
	if test "$ENABLE_MULTILIB" = yes && ls | grep -q multilib; then
		$APT_GET install "gcc-$GCC_VER-multilib$HOST_ARCH_SUFFIX"
	else
		rm -vf ./*multilib*.deb
		$APT_GET install "gcc-$GCC_VER$HOST_ARCH_SUFFIX"
	fi
	compiler="`dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_TYPE`-gcc-$GCC_VER"
	if ! which "$compiler"; then echo "$compiler missing in stage1 gcc package"; exit 1; fi
	if ! drop_privs "$compiler" -x c -c /dev/null -o test.o; then echo "stage1 gcc fails to execute"; exit 1; fi
	if ! test -f test.o; then echo "stage1 gcc fails to create binaries"; exit 1; fi
	check_arch test.o "$HOST_ARCH"
	touch "$REPODIR/stamps/gcc_1"
	cd ..
	drop_privs rm -Rf gcc1
fi
progress_mark "cross gcc stage1 build"

# replacement for cross-gcc-defaults
for prog in c++ cpp g++ gcc gcc-ar gcc-ranlib gfortran; do
	ln -fs "`dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_TYPE`-$prog-$GCC_VER" "/usr/bin/`dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_GNU_TYPE`-$prog"
done

if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = hurd; then
if test -f "$REPODIR/stamps/hurd_1"; then
	echo "skipping rebuild of hurd stage1"
else
	cross_build_setup hurd hurd_1
	apt_get_build_dep "-a$HOST_ARCH" --arch-only -P stage1 ./
	drop_privs dpkg-buildpackage -B "-a$HOST_ARCH" -Pstage1 -uc -us
	cd ..
	ls -l
	pickup_packages *.changes
	touch "$REPODIR/stamps/hurd_1"
	cd ..
	drop_privs rm -Rf hurd_1
fi
progress_mark "hurd stage1 cross build"
fi

if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = hurd; then
if test -f "$REPODIR/stamps/mig_1"; then
	echo "skipping rebuild of mig cross"
else
	cross_build_setup mig mig_1
	apt_get_install dpkg-dev debhelper dh-exec dh-autoreconf "gnumach-dev:$HOST_ARCH" flex libfl-dev bison
	drop_privs dpkg-buildpackage -d -B "--target-arch=$HOST_ARCH" -uc -us
	cd ..
	ls -l
	pickup_packages *.changes
	touch "$REPODIR/stamps/mig_1"
	cd ..
	drop_privs rm -Rf mig_1
fi
progress_mark "cross mig build"
fi

# we'll have to remove build arch multilibs to be able to install host arch multilibs
apt_get_remove $(dpkg-query -W "libc[0-9]*-*:$(dpkg --print-architecture)" | sed "s/\\s.*//;/:$(dpkg --print-architecture)/d")

if test -f "$REPODIR/stamps/${LIBC_NAME}_2"; then
	echo "skipping rebuild of $LIBC_NAME stage2"
else
	cross_build_setup "$LIBC_NAME" "${LIBC_NAME}_2"
	if test "$LIBC_NAME" = glibc; then
		"$(get_hook builddep glibc)" "$HOST_ARCH" stage2
	else
		apt_get_build_dep "-a$HOST_ARCH" --arch-only ./
	fi
	(
		case "$LIBC_NAME:$ENABLE_MULTILIB" in
			glibc:yes) profiles=stage2 ;;
			glibc:no) profiles=stage2,nobiarch ;;
			*) profiles=cross,nocheck ;;
		esac
		# tell unmet build depends
		drop_privs dpkg-checkbuilddeps -B "-a$HOST_ARCH" "-P$profiles" || :
		export DEB_GCC_VERSION="-$GCC_VER"
		drop_privs_exec dpkg-buildpackage -B -uc -us "-a$HOST_ARCH" -d "-P$profiles" || buildpackage_failed "$?"
	)
	cd ..
	ls -l
	if test "$LIBC_NAME" = musl; then
		pickup_packages *.changes
		dpkg -i musl*.deb
	else
		if test "$ENABLE_MULTIARCH_GCC" = yes; then
			pickup_packages *.changes
			dpkg -i libc[0-9]*.deb
		else
			for pkg in libc[0-9]*.deb; do
				# dpkg-cross cannot handle these
				test "${pkg%%_*}" = "libc6-xen" && continue
				test "${pkg%%_*}" = "libc6.1-alphaev67" && continue
				drop_privs dpkg-cross -M -a "$HOST_ARCH" -X tzdata -X libc-bin -X libc-dev-bin -X multiarch-support -b "$pkg"
			done
			pickup_packages *.changes ./*-cross_*.deb
			dpkg -i libc[0-9]*-cross_*.deb
		fi
	fi
	touch "$REPODIR/stamps/${LIBC_NAME}_2"
	compare_native ./*.deb
	cd ..
	drop_privs rm -Rf "${LIBC_NAME}_2"
fi
progress_mark "$LIBC_NAME stage2 cross build"

if test -f "$REPODIR/stamps/gcc_3"; then
	echo "skipping rebuild of gcc stage3"
else
	apt_get_install debhelper gawk patchutils bison flex lsb-release quilt libtool $GCC_AUTOCONF zlib1g-dev libmpc-dev libmpfr-dev libgmp-dev dejagnu autogen systemtap-sdt-dev sharutils "binutils$HOST_ARCH_SUFFIX" time
	if test "$HOST_ARCH" = hppa; then
		$APT_GET install binutils-hppa64-linux-gnu
	fi
	if test "$ENABLE_MULTIARCH_GCC" = yes; then
		apt_get_install "libc-dev:$HOST_ARCH" $(echo $MULTILIB_NAMES | sed "s/\(\S\+\)/libc6-dev-\1:$HOST_ARCH/g")
	else
		case "$LIBC_NAME" in
			glibc)
				apt_get_install "libc6-dev-$HOST_ARCH-cross" $(echo $MULTILIB_NAMES | sed "s/\(\S\+\)/libc6-dev-\1-$HOST_ARCH-cross/g")
			;;
			musl)
				apt_get_install "musl-dev-$HOST_ARCH-cross"
			;;
		esac
	fi
	cross_build_setup "gcc-$GCC_VER" gcc3
	check_binNMU
	dpkg-checkbuilddeps -a$HOST_ARCH || : # tell unmet build depends
	echo "$HOST_ARCH" > debian/target
	(
		nolang=${GCC_NOLANG:-}
		test "$ENABLE_MULTILIB" = yes || nolang=$(set_add "$nolang" biarch)
		export DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS${nolang:+ nolang=$(join_words , $nolang)}"
		if test "$ENABLE_MULTIARCH_GCC" = yes; then
			export with_deps_on_target_arch_pkgs=yes
		else
			export WITH_SYSROOT=/
		fi
		export gcc_cv_libc_provides_ssp=yes
		export gcc_cv_initfini_array=yes
		drop_privs dpkg-buildpackage -d -T control
		drop_privs dpkg-buildpackage -d -T clean
		dpkg-checkbuilddeps || : # tell unmet build depends again after rewriting control
		drop_privs_exec dpkg-buildpackage -d -b -uc -us
	)
	cd ..
	ls -l
	if test "$ENABLE_MULTIARCH_GCC" = yes; then
		drop_privs changestool ./*.changes dumbremove "gcc-${GCC_VER}-base_"*"_$(dpkg --print-architecture).deb"
		drop_privs rm "gcc-${GCC_VER}-base_"*"_$(dpkg --print-architecture).deb"
	fi
	pickup_packages *.changes
	# avoid file conflicts between differently staged M-A:same packages
	apt_get_remove "gcc-$GCC_VER-base:$HOST_ARCH"
	drop_privs rm -fv gcc-*-plugin-*.deb gcj-*.deb gdc-*.deb ./*objc*.deb ./*-dbg_*.deb
	dpkg -i *.deb
	compiler="`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_GNU_TYPE`-gcc-$GCC_VER"
	if ! which "$compiler"; then echo "$compiler missing in stage3 gcc package"; exit 1; fi
	if ! drop_privs "$compiler" -x c -c /dev/null -o test.o; then echo "stage3 gcc fails to execute"; exit 1; fi
	if ! test -f test.o; then echo "stage3 gcc fails to create binaries"; exit 1; fi
	check_arch test.o "$HOST_ARCH"
	mkdir -p "/usr/include/$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_MULTIARCH)"
	touch /usr/include/`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_MULTIARCH`/include_path_test_header.h
	preproc="`dpkg-architecture -a$HOST_ARCH -qDEB_HOST_GNU_TYPE`-cpp-$GCC_VER"
	if ! echo '#include "include_path_test_header.h"' | drop_privs "$preproc" -E -; then echo "stage3 gcc fails to search /usr/include/<triplet>"; exit 1; fi
	touch "$REPODIR/stamps/gcc_3"
	if test "$ENABLE_MULTIARCH_GCC" = yes; then
		compare_native ./*.deb
	fi
	cd ..
	drop_privs rm -Rf gcc3
fi
progress_mark "cross gcc stage3 build"

if test "$ENABLE_MULTIARCH_GCC" != yes; then
if test -f "$REPODIR/stamps/gcc_f1"; then
	echo "skipping rebuild of gcc rtlibs"
else
	apt_get_install debhelper gawk patchutils bison flex lsb-release quilt libtool $GCC_AUTOCONF zlib1g-dev libmpc-dev libmpfr-dev libgmp-dev dejagnu autogen systemtap-sdt-dev sharutils "binutils$HOST_ARCH_SUFFIX" "libc-dev:$HOST_ARCH" time
	if test "$HOST_ARCH" = hppa; then
		$APT_GET install binutils-hppa64-linux-gnu
	fi
	if test "$ENABLE_MULTILIB" = yes -a -n "$MULTILIB_NAMES"; then
		$APT_GET install $(echo $MULTILIB_NAMES | sed "s/\(\S\+\)/libc6-dev-\1-$HOST_ARCH-cross libc6-dev-\1:$HOST_ARCH/g")
	fi
	cross_build_setup "gcc-$GCC_VER" gcc_f1
	check_binNMU
	dpkg-checkbuilddeps || : # tell unmet build depends
	echo "$HOST_ARCH" > debian/target
	(
		export DEB_STAGE=rtlibs
		nolang=${GCC_NOLANG:-}
		test "$ENABLE_MULTILIB" = yes || nolang=$(set_add "$nolang" biarch)
		export DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS${nolang:+ nolang=$(join_words , $nolang)}"
		export WITH_SYSROOT=/
		drop_privs dpkg-buildpackage -d -T control
		cat debian/control
		dpkg-checkbuilddeps || : # tell unmet build depends again after rewriting control
		drop_privs_exec dpkg-buildpackage -d -b -uc -us
	)
	cd ..
	ls -l
	rm -vf "gcc-$GCC_VER-base_"*"_$(dpkg --print-architecture).deb"
	pickup_additional_packages *.deb
	$APT_GET dist-upgrade
	dpkg -i ./*.deb
	touch "$REPODIR/stamps/gcc_f1"
	cd ..
	drop_privs rm -Rf gcc_f1
fi
progress_mark "gcc cross rtlibs build"
fi

# install something similar to crossbuild-essential
apt_get_install "binutils$HOST_ARCH_SUFFIX" "gcc-$GCC_VER$HOST_ARCH_SUFFIX" "g++-$GCC_VER$HOST_ARCH_SUFFIX" "libc-dev:$HOST_ARCH"

apt_get_remove libc6-i386 # breaks cross builds

if dpkg-architecture "-a$HOST_ARCH" -ihurd-any; then
if test -f "$REPODIR/stamps/hurd_2"; then
	echo "skipping rebuild of hurd stage2"
else
	cross_build_setup hurd hurd_2
	apt_get_build_dep "-a$HOST_ARCH" --arch-only -P stage2 ./
	drop_privs dpkg-buildpackage -B "-a$HOST_ARCH" -Pstage2 -uc -us
	cd ..
	ls -l
	pickup_packages *.changes
	touch "$REPODIR/stamps/hurd_2"
	cd ..
	drop_privs rm -Rf hurd_2
fi
apt_get_install "hurd-dev:$HOST_ARCH"
progress_mark "hurd stage3 cross build"
fi

# Skip libxcrypt for musl until #947193 is resolved.
if ! dpkg-architecture "-a$HOST_ARCH" -i musl-linux-any; then
	# libcrypt1-dev is defacto build-essential, because unstaged libc6-dev (and
	# later build-essential) depends on it.
	cross_build libxcrypt
	apt_get_install "libcrypt1-dev:$HOST_ARCH"
	# is defacto build-essential
fi

$APT_GET install dose-builddebcheck dctrl-tools

call_dose_builddebcheck() {
	local package_list source_list errcode
	package_list=`mktemp packages.XXXXXXXXXX`
	source_list=`mktemp sources.XXXXXXXXXX`
	cat /var/lib/apt/lists/*_Packages - > "$package_list" <<EOF
Package: crossbuild-essential-$HOST_ARCH
Version: 0
Architecture: $HOST_ARCH
Multi-Arch: foreign
Depends: libc-dev
Description: fake crossbuild-essential package for dose-builddebcheck

EOF
	sed -i -e '/^Conflicts:.* libc[0-9][^ ]*-dev\(,\|$\)/d' "$package_list" # also make dose ignore the glibc conflict
	apt-cache show "gcc-${GCC_VER}-base=installed" libgcc-s1=installed libstdc++6=installed libatomic1=installed >> "$package_list" # helps when pulling gcc from experimental
	cat /var/lib/apt/lists/*_Sources > "$source_list"
	errcode=0
	dose-builddebcheck --deb-tupletable=/usr/share/dpkg/tupletable --deb-cputable=/usr/share/dpkg/cputable "--deb-native-arch=$(dpkg --print-architecture)" "--deb-host-arch=$HOST_ARCH" "$@" "$package_list" "$source_list" || errcode=$?
	if test "$errcode" -gt 1; then
		echo "dose-builddebcheck failed with error code $errcode" 1>&2
		exit 1
	fi
	rm -f "$package_list" "$source_list"
}

# determine whether a given binary package refers to an arch:all package
# $1 is a binary package name
is_arch_all() {
	grep-dctrl -P -X "$1" -a -F Architecture all -s /var/lib/apt/lists/*_Packages
}

# determine which source packages build a given binary package
# $1 is a binary package name
# prints a set of source packages
what_builds() {
	local newline pattern source
	newline='
'
	pattern=`echo "$1" | sed 's/[+.]/\\\\&/g'`
	pattern="$newline $pattern "
	# exit codes 0 and 1 signal successful operation
	source=`grep-dctrl -F Package-List -e "$pattern" -s Package -n /var/lib/apt/lists/*_Sources || test "$?" -eq 1`
	set_create "$source"
}

# determine a set of source package names which are essential to some
# architecture
discover_essential() {
	set_create "$(grep-dctrl -F Package-List -e '\bessential=yes\b' -s Package -n /var/lib/apt/lists/*_Sources)"
}

need_packages=
add_need() { need_packages=`set_add "$need_packages" "$1"`; }
built_packages=
mark_built() {
	need_packages=`set_discard "$need_packages" "$1"`
	built_packages=`set_add "$built_packages" "$1"`
}

for pkg in $(discover_essential); do
	if set_contains "$automatic_packages" "$pkg"; then
		echo "rebootstrap-debug: automatically scheduling essential package $pkg"
		add_need "$pkg"
	else
		echo "rebootstrap-debug: not scheduling essential package $pkg"
	fi
done
add_need acl # by coreutils, systemd
add_need apt # almost essential
add_need attr # by coreutils, libcap-ng
add_need autogen # by gcc-VER, gnutls28
add_need blt # by pythonX.Y
add_need bsdmainutils # for man-db
add_need bzip2 # by perl
add_need db-defaults # by perl, python2.7, python3.5
add_need expat # by unbound
add_need file # by gcc-6, for debhelper
add_need flex # by libsemanage, pam
add_need fribidi # by newt
add_need gmp # by gnutls28
add_need gnupg2 # for apt
test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux && add_need gpm # by ncurses
add_need groff # for man-db
test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux && add_need kmod # by systemd
add_need icu # by libxml2
add_need krb5 # by audit
add_need libatomic-ops # by gcc-VER
dpkg-architecture "-a$HOST_ARCH" -ilinux-any && add_need libcap2 # by systemd
add_need libdebian-installer # by cdebconf
add_need libevent # by unbound
add_need libidn2 # by gnutls28
add_need libgcrypt20 # by libprelude, cryptsetup
dpkg-architecture "-a$HOST_ARCH" -ilinux-any && add_need libsepol # by libselinux
if dpkg-architecture "-a$HOST_ARCH" -ihurd-any; then
	add_need libsystemd-dummy # by nghttp2
fi
add_need libtasn1-6 # by gnutls28
add_need libtextwrap # by cdebconf
add_need libunistring # by gnutls28
add_need libxrender # by cairo
add_need libzstd # by systemd
add_need lz4 # by systemd
add_need make-dfsg # for build-essential
add_need man-db # for debhelper
add_need mawk # for base-files (alternatively: gawk)
add_need mpclib3 # by gcc-VER
add_need mpdecimal # by python3.X
add_need mpfr4 # by gcc-VER
add_need nettle # by unbound, gnutls28
add_need openssl # by cyrus-sasl2
add_need p11-kit # by gnutls28
add_need patch # for dpkg-dev
add_need pcre2 # by libselinux
add_need popt # by newt
add_need slang2 # by cdebconf, newt
add_need sqlite3 # by python2.7
add_need tcl8.6 # by newt
add_need tcltk-defaults # by python2.7
add_need tcp-wrappers # by audit
add_need xz-utils # by libxml2

automatically_cross_build_packages() {
	local need_packages_comma_sep dosetmp profiles buildable new_needed line pkg missing source
	while test -n "$need_packages"; do
		echo "checking packages with dose-builddebcheck: $need_packages"
		need_packages_comma_sep=`echo $need_packages | sed 's/ /,/g'`
		dosetmp=`mktemp -t doseoutput.XXXXXXXXXX`
		profiles="$DEFAULT_PROFILES"
		if test "$ENABLE_MULTILIB" = no; then
			profiles=$(set_add "$profiles" nobiarch)
		fi
		profiles=$(echo "$profiles" | tr ' ' ,)
		call_dose_builddebcheck --successes --failures --explain --latest=1 --deb-drop-b-d-indep "--deb-profiles=$profiles" "--checkonly=$need_packages_comma_sep" >"$dosetmp"
		buildable=
		new_needed=
		while IFS= read -r line; do
			case "$line" in
				"  package: "*)
					pkg=${line#  package: }
					pkg=${pkg#src:} # dose3 << 4.1
				;;
				"  status: ok")
					buildable=`set_add "$buildable" "$pkg"`
				;;
				"      unsat-dependency: "*)
					missing=${line#*: }
					missing=${missing%% | *} # drop alternatives
					missing=${missing% (* *)} # drop version constraint
					missing=${missing%:$HOST_ARCH} # skip architecture
					if is_arch_all "$missing"; then
						echo "rebootstrap-warning: $pkg misses dependency $missing which is arch:all"
					else
						source=`what_builds "$missing"`
						case "$source" in
							"")
								echo "rebootstrap-warning: $pkg transitively build-depends on $missing, but no source package could be determined"
							;;
							*" "*)
								echo "rebootstrap-warning: $pkg transitively build-depends on $missing, but it is build from multiple source packages: $source"
							;;
							*)
								if set_contains "$built_packages" "$source"; then
									echo "rebootstrap-warning: $pkg transitively build-depends on $missing, which is built from $source, which is supposedly already built"
								elif set_contains "$need_packages" "$source"; then
									echo "rebootstrap-debug: $pkg transitively build-depends on $missing, which is built from $source and already scheduled for building"
								elif set_contains "$automatic_packages" "$source"; then
									new_needed=`set_add "$new_needed" "$source"`
								else
									echo "rebootstrap-warning: $pkg transitively build-depends on $missing, which is built from $source but not automatic"
								fi
							;;
						esac
					fi
				;;
			esac
		done < "$dosetmp"
		rm "$dosetmp"
		echo "buildable packages: $buildable"
		echo "new packages needed: $new_needed"
		test -z "$buildable" -a -z "$new_needed" && break
		for pkg in $buildable; do
			echo "cross building $pkg"
			cross_build "$pkg"
			mark_built "$pkg"
		done
		need_packages=`set_union "$need_packages" "$new_needed"`
	done
	echo "done automatically cross building packages. left: $need_packages"
}

assert_built() {
	local missing_pkgs missing_pkgs_comma_sep profiles
	missing_pkgs=`set_difference "$1" "$built_packages"`
	test -z "$missing_pkgs" && return 0
	echo "rebootstrap-error: missing asserted packages: $missing_pkgs"
	missing_pkgs=`set_union "$missing_pkgs" "$need_packages"`
	missing_pkgs_comma_sep=`echo $missing_pkgs | sed 's/ /,/g'`
	profiles="$DEFAULT_PROFILES"
	if test "$ENABLE_MULTILIB" = no; then
		profiles=$(set_add "$profiles" nobiarch)
	fi
	profiles=$(echo "$profiles" | tr ' ' ,)
	call_dose_builddebcheck --failures --explain --latest=1 --deb-drop-b-d-indep "--deb-profiles=$profiles" "--checkonly=$missing_pkgs_comma_sep"
	return 1
}

automatically_cross_build_packages

cross_build zlib "$(if test "$ENABLE_MULTILIB" != yes; then echo stage1; fi)"
mark_built zlib
# needed by dpkg, file, gnutls28, libpng1.6, libtool, libxml2, perl, slang2, tcl8.6, util-linux

automatically_cross_build_packages

cross_build libtool
mark_built libtool
# needed by guile-X.Y, libffi

automatically_cross_build_packages

cross_build ncurses
mark_built ncurses
# needed by bash, bsdmainutils, dpkg, guile-X.Y, readline, slang2

automatically_cross_build_packages

cross_build readline
mark_built readline
# needed by gnupg2, guile-X.Y, libxml2

automatically_cross_build_packages

if dpkg-architecture "-a$HOST_ARCH" -ilinux-any; then
	assert_built "libsepol pcre2"
	cross_build libselinux "nopython noruby" libselinux_1
	mark_built libselinux
# needed by coreutils, dpkg, findutils, glibc, sed, tar, util-linux

automatically_cross_build_packages
fi # $HOST_ARCH matches linux-any

dpkg-architecture "-a$1" -ilinux-any && assert_built libselinux
assert_built "ncurses zlib"
cross_build util-linux stage1 util-linux_1
mark_built util-linux
# essential, needed by e2fsprogs

automatically_cross_build_packages

cross_build db5.3 "pkg.db5.3.notcl nojava" db5.3_1
mark_built db5.3
# needed by perl, python2.7, needed for db-defaults

automatically_cross_build_packages

cross_build libxml2 nopython libxml2_1
mark_built libxml2
# needed by autogen

automatically_cross_build_packages

cross_build cracklib2 nopython cracklib2_1
mark_built cracklib2
# needed by pam

automatically_cross_build_packages

cross_build build-essential
mark_built build-essential
# build-essential

automatically_cross_build_packages

cross_build pam stage1 pam_1
mark_built pam
# needed by shadow

automatically_cross_build_packages

if test -f "$REPODIR/stamps/cyrus-sasl2_1"; then
	echo "skipping stage1 rebuild of cyrus-sasl2"
else
	builddep_cyrus_sasl2 "$HOST_ARCH"
	cross_build_setup cyrus-sasl2 cyrus-sasl2_1
	check_binNMU
	dpkg-checkbuilddeps -B "-a$HOST_ARCH" -Ppkg.cyrus-sasl2.nogssapi,pkg.cyrus-sasl2.noldap,pkg.cyrus-sasl2.nosql || : # tell unmet build depends
	drop_privs dpkg-buildpackage "-a$HOST_ARCH" -Ppkg.cyrus-sasl2.nogssapi,pkg.cyrus-sasl2.noldap,pkg.cyrus-sasl2.nosql -B -d -uc -us
	cd ..
	ls -l
	pickup_packages *.changes
	touch "$REPODIR/stamps/cyrus-sasl2_1"
	compare_native ./*.deb
	cd ..
	drop_privs rm -Rf cyrus-sasl2_1
fi
progress_mark "cyrus-sasl2 stage1 cross build"
mark_built cyrus-sasl2
# needed by openldap

automatically_cross_build_packages

assert_built "libevent expat nettle"
dpkg-architecture "-a$HOST_ARCH" -ilinux-any || assert_built libbsd
cross_build unbound pkg.unbound.libonly unbound_1
mark_built unbound
# needed by gnutls28

automatically_cross_build_packages

assert_built "gmp libidn2 autogen p11-kit libtasn1-6 unbound libunistring nettle"
cross_build gnutls28 noguile gnutls28_1
mark_built gnutls28
# needed by libprelude, openldap, curl

automatically_cross_build_packages

assert_built "gnutls28 cyrus-sasl2"
cross_build openldap pkg.openldap.noslapd openldap_1
mark_built openldap
# needed by curl

automatically_cross_build_packages

if apt-cache showsrc systemd | grep -q "^Build-Depends:.*gnu-efi[^,]*[[ ]$HOST_ARCH[] ]"; then
cross_build gnu-efi
mark_built gnu-efi
# needed by systemd

automatically_cross_build_packages
fi

if test "$(dpkg-architecture "-a$HOST_ARCH" -qDEB_HOST_ARCH_OS)" = linux; then
if apt-cache showsrc man-db systemd | grep -q "^Build-Depends:.*libseccomp-dev[^,]*[[ ]$HOST_ARCH[] ]"; then
	cross_build libseccomp nopython libseccomp_1
	mark_built libseccomp
# needed by man-db, systemd

	automatically_cross_build_packages
fi


assert_built "libcap2 pam libselinux acl xz-utils libgcrypt20 kmod util-linux libzstd"
if apt-cache showsrc systemd | grep -q "^Build-Depends:.*libseccomp-dev[^,]*[[ ]$HOST_ARCH[] ]" debian/control; then
	assert_built libseccomp
fi
cross_build systemd stage1 systemd_1
mark_built systemd
# needed by util-linux

automatically_cross_build_packages

assert_built attr
cross_build libcap-ng nopython libcap-ng_1
mark_built libcap-ng
# needed by audit

automatically_cross_build_packages

assert_built "gnutls28 libgcrypt20 libtool"
cross_build libprelude "nolua noperl nopython noruby" libprelude_1
mark_built libprelude
# needed by audit

automatically_cross_build_packages

assert_built "zlib bzip2 xz-utils"
cross_build elfutils pkg.elfutils.nodebuginfod
mark_built elfutils
# needed by glib2.0

automatically_cross_build_packages

assert_built "libcap-ng krb5 openldap libprelude tcp-wrappers"
cross_build audit nopython audit_1
mark_built audit
# needed by libsemanage

automatically_cross_build_packages

assert_built "audit bzip2 libselinux libsepol"
cross_build libsemanage "nocheck nopython noruby" libsemanage_1
mark_built libsemanage
# needed by shadow

automatically_cross_build_packages
fi # $HOST_ARCH matches linux-any

dpkg-architecture "-a$1" -ilinux-any && assert_built "audit libcap-ng libselinux systemd"
assert_built "ncurses zlib"
cross_build util-linux # stageless
# essential

automatically_cross_build_packages

cross_build brotli nopython brotli_1
mark_built brotli
# needed by curl

automatically_cross_build_packages

cross_build gdbm pkg.gdbm.nodietlibc gdbm_1
mark_built gdbm
# needed by man-db, perl, python2.7

automatically_cross_build_packages

cross_build newt stage1 newt_1
mark_built newt
# needed by cdebconf

automatically_cross_build_packages

cross_build cdebconf pkg.cdebconf.nogtk cdebconf_1
mark_built cdebconf
# needed by base-passwd

automatically_cross_build_packages

assert_built "$need_packages"

echo "checking installability of build-essential with dose"
apt_get_install botch
package_list=$(mktemp -t packages.XXXXXXXXXX)
grep-dctrl --exact --field Architecture '(' "$HOST_ARCH" --or all ')' /var/lib/apt/lists/*_Packages > "$package_list"
botch-distcheck-more-problems "--deb-native-arch=$HOST_ARCH" --successes --failures --explain --checkonly "build-essential:$HOST_ARCH" "--bg=deb://$package_list" "--fg=deb://$package_list" || :
rm -f "$package_list"
