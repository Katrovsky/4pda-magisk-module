#!/bin/bash

MODULE_TEMPLATE_DIR="revanced-magisk"
TEMP_DIR="temp"
BUILD_DIR="build"
ARM64_V8A="arm64-v8a"
ARM_V7A="arm-v7a"

GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-$GITHUB_REPO_FALLBACK}
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}

WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:102.0) Gecko/20100101 Firefox/102.0"

get_prebuilts() {
	echo "Getting prebuilts"
	mkdir -p "$TEMP_DIR"
	RV_CLI_URL=$(req https://api.github.com/repos/revanced/revanced-cli/releases/latest - | tr -d ' ' | sed -n 's/.*"browser_download_url":"\(.*jar\)".*/\1/p')
	RV_CLI_JAR="${TEMP_DIR}/$(echo "$RV_CLI_URL" | awk -F/ '{ print $NF }')"
	log "CLI: ${RV_CLI_JAR#"$TEMP_DIR/"}"

	RV_INTEGRATIONS_URL=$(req https://api.github.com/repos/revanced/revanced-integrations/releases/latest - | tr -d ' ' | sed -n 's/.*"browser_download_url":"\(.*apk\)".*/\1/p')
	RV_INTEGRATIONS_APK="${TEMP_DIR}/$(echo "$RV_INTEGRATIONS_URL" | awk '{n=split($0, arr, "/"); printf "%s-%s.apk", substr(arr[n], 0, length(arr[n]) - 4), arr[n-1]}')"
	log "Integrations: ${RV_INTEGRATIONS_APK#"$TEMP_DIR/"}"

	RV_PATCHES_URL=$(req https://api.github.com/repos/revanced/revanced-patches/releases/latest - | tr -d ' ' | sed -n 's/.*"browser_download_url":"\(.*jar\)".*/\1/p')
	RV_PATCHES_JAR="${TEMP_DIR}/$(echo "$RV_PATCHES_URL" | awk -F/ '{ print $NF }')"
	log "Patches: ${RV_PATCHES_JAR#"$TEMP_DIR/"}"

	dl_if_dne "$RV_CLI_JAR" "$RV_CLI_URL"
	dl_if_dne "$RV_INTEGRATIONS_APK" "$RV_INTEGRATIONS_URL"
	dl_if_dne "$RV_PATCHES_JAR" "$RV_PATCHES_URL"
}

dl_xdelta() {
	XDELTA_aarch64="${TEMP_DIR}/xdelta_aarch64"
	XDELTA_arm="${TEMP_DIR}/xdelta_arm"

	dl_if_dne "${XDELTA_aarch64}.deb" "https://grimler.se/termux/termux-main/pool/main/x/xdelta3/xdelta3_3.1.0-1_aarch64.deb"
	ar x "${XDELTA_aarch64}.deb" data.tar.xz
	tar -vxf data.tar.xz ./data/data/com.termux/files/usr/bin/xdelta3 --strip-components 7
	mv -f xdelta3 $XDELTA_aarch64
	rm data.tar.xz

	dl_if_dne "${XDELTA_arm}.deb" "https://grimler.se/termux/termux-main/pool/main/x/xdelta3/xdelta3_3.1.0-1_arm.deb"
	ar x "${XDELTA_arm}.deb" data.tar.xz
	tar -vxf data.tar.xz ./data/data/com.termux/files/usr/bin/xdelta3 --strip-components 7
	mv -f xdelta3 $XDELTA_arm
	rm data.tar.xz
}

set_prebuilts() {
	[ -d "$TEMP_DIR" ] || {
		echo "${TEMP_DIR} directory could not be found"
		exit 1
	}
	RV_CLI_JAR=$(find "$TEMP_DIR" -maxdepth 1 -name "revanced-cli-*" | tail -n1)
	log "CLI: ${RV_CLI_JAR#"$TEMP_DIR/"}"
	RV_INTEGRATIONS_APK=$(find "$TEMP_DIR" -maxdepth 1 -name "app-release-unsigned-*" | tail -n1)
	log "Integrations: ${RV_INTEGRATIONS_APK#"$TEMP_DIR/"}"
	RV_PATCHES_JAR=$(find "$TEMP_DIR" -maxdepth 1 -name "revanced-patches-*" | tail -n1)
	log "Patches: ${RV_PATCHES_JAR#"$TEMP_DIR/"}"
}

reset_template() {
	echo "# utils" >"${MODULE_TEMPLATE_DIR}/service.sh"
	echo "# utils" >"${MODULE_TEMPLATE_DIR}/post-fs-data.sh"
	echo "# utils" >"${MODULE_TEMPLATE_DIR}/common/install.sh"
	echo "# utils" >"${MODULE_TEMPLATE_DIR}/module.prop"
	rm -rf ${MODULE_TEMPLATE_DIR}/*xdelta*
}

req() {
	wget -nv -O "$2" --header="$WGET_HEADER" "$1"
}

dl_if_dne() {
	if [ ! -f "$1" ]; then
		echo -e "\nGetting '$1' from '$2'"
		req "$2" "$1"
	fi
}

log() {
	echo -e "$1  " >>build.log
}

dl_apk() {
	local url=$1 regexp=$2 output=$3
	url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n "s/href=\"/@/g; s;.*${regexp}.*;\1;p")"
	echo "$url"
	url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
	url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
	req "$url" "$output"
}

get_apk_vers() {
	req "$1" - | sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p'
}

get_patch_last_supported_ver() {
	declare -r supported_versions=$(unzip -p "$RV_PATCHES_JAR" | strings -s , | sed -rn "s/.*${1},versions,(([0-9.]*,*)*),Lk.*/\1/p")
	echo "${supported_versions##*,}"
}

get_xdelta() {
	echo "Getting xdelta for ${1}"
	xdelta3 -fs "$1" "$2" "$3"
}

patch_apk() {
	local stock_input=$1 patched_output=$2 patcher_args=$3
	# shellcheck disable=SC2086
	java -jar "$RV_CLI_JAR" -c -a "$stock_input" -o "$patched_output" -b "$RV_PATCHES_JAR" --keystore=ks.keystore $patcher_args
}

zip_module() {
	local xdelta_patch=$1 module_name=$2
	cp -f "$xdelta_patch" "${MODULE_TEMPLATE_DIR}/rv.xdelta"
	cp -f "$XDELTA_aarch64" "${MODULE_TEMPLATE_DIR}"
	cp -f "$XDELTA_arm" "${MODULE_TEMPLATE_DIR}"

	cd "$MODULE_TEMPLATE_DIR" || exit 1
	zip -FSr "../${BUILD_DIR}/${module_name}" .
	cd ..
}

build_reddit() {
	echo "Building Reddit"
	local last_ver
	last_ver=$(get_patch_last_supported_ver "frontpage")
	last_ver="${last_ver:-$(get_apk_vers "https://www.apkmirror.com/apk/redditinc/reddit/" | head -n 1)}"

	echo "Choosing version '${last_ver}'"
	local stock_apk="${TEMP_DIR}/reddit-stock-v${last_ver}.apk" patched_apk="${BUILD_DIR}/reddit-revanced-v${last_ver}.apk"
	if [ ! -f "$stock_apk" ]; then
		declare -r dl_url=$(dl_apk "https://www.apkmirror.com/apk/redditinc/reddit/reddit-${last_ver//./-}-release/" \
			"APK</span>[^@]*@\([^#]*\)" \
			"$stock_apk")
		log "\nReddit version: ${last_ver}"
		log "downloaded from: [APKMirror - Reddit]($dl_url)"
	fi
	patch_apk "$stock_apk" "$patched_apk" "-r"
}

build_twitter() {
	echo "Building Twitter"
	local last_ver
	last_ver=$(get_patch_last_supported_ver "twitter")
	last_ver="${last_ver:-$(get_apk_vers "https://www.apkmirror.com/apk/twitter-inc/" | grep release | head -n 1)}"

	echo "Choosing version '${last_ver}'"
	local stock_apk="${TEMP_DIR}/twitter-stock-v${last_ver}.apk" patched_apk="${BUILD_DIR}/twitter-revanced-v${last_ver}.apk"
	if [ ! -f "$stock_apk" ]; then
		declare -r dl_url=$(dl_apk "https://www.apkmirror.com/apk/twitter-inc/twitter/twitter-${last_ver//./-}-release/" \
			"APK</span>[^@]*@\([^#]*\)" \
			"$stock_apk")
		log "\nTwitter version: ${last_ver}"
		log "downloaded from: [APKMirror - Twitter]($dl_url)"
	fi
	patch_apk "$stock_apk" "$patched_apk" "-r"
}

build_yt() {
	echo "Building YouTube"
	reset_template
	local last_ver
	last_ver=$(get_patch_last_supported_ver "youtube")
	echo "Choosing version '${last_ver}'"

	local stock_apk="${TEMP_DIR}/youtube-stock-v${last_ver}.apk" patched_apk="${TEMP_DIR}/youtube-revanced-v${last_ver}.apk"
	if [ ! -f "$stock_apk" ]; then
		declare -r dl_url=$(dl_apk "https://www.apkmirror.com/apk/google-inc/youtube/youtube-${last_ver//./-}-release/" \
			"APK</span>[^@]*@\([^#]*\)" \
			"$stock_apk")
		log "\nYouTube version: ${last_ver}"
		log "downloaded from: [APKMirror - YouTube]($dl_url)"
	fi
	patch_apk "$stock_apk" "$patched_apk" "${YT_PATCHER_ARGS} -m ${RV_INTEGRATIONS_APK}"

	if [[ "$YT_PATCHER_ARGS" != *"-e microg-support"* ]] && [[ "$YT_PATCHER_ARGS" != *"--exclusive"* ]] || [[ "$YT_PATCHER_ARGS" == *"-i microg-support"* ]]; then
		mv -f "$patched_apk" build
		echo "Built YouTube (no root) '${BUILD_DIR}/${patched_apk}'"
		return
	fi

	service_sh "com.google.android.youtube"
	postfsdata_sh "com.google.android.youtube"
	install_sh "com.google.android.youtube" "$last_ver"
	module_prop "ytrv-magisk" \
		"YouTube ReVanced" \
		"$last_ver" \
		"mounts base.apk for YouTube ReVanced" \
		"https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/update/yt-update.json"

	local output="youtube-revanced-magisk-v${last_ver}-all.zip"
	local xdelta="${TEMP_DIR}/youtube-revanced-v${last_ver}.xdelta"
	get_xdelta "$stock_apk" "$patched_apk" "$xdelta"
	zip_module "$xdelta" "$output"
	echo "Built YouTube: '${BUILD_DIR}/${output}'"
}

build_music() {
	echo "Building YouTube Music"
	reset_template
	local arch=$1 last_ver
	last_ver=$(get_patch_last_supported_ver "music")
	echo "Choosing version '${last_ver}'"

	local stock_apk="${TEMP_DIR}/music-stock-v${last_ver}-${arch}.apk" patched_apk="${TEMP_DIR}/music-revanced-v${last_ver}-${arch}.apk"
	if [ ! -f "$stock_apk" ]; then
		if [ "$arch" = "$ARM64_V8A" ]; then
			local regexp_arch='arm64-v8a</div>[^@]*@\([^"]*\)'
		elif [ "$arch" = "$ARM_V7A" ]; then
			local regexp_arch='armeabi-v7a</div>[^@]*@\([^"]*\)'
		fi
		declare -r dl_url=$(dl_apk "https://www.apkmirror.com/apk/google-inc/youtube-music/youtube-music-${last_ver//./-}-release/" \
			"$regexp_arch" \
			"$stock_apk")
		log "\nYouTube Music (${arch}) version: ${last_ver}"
		log "downloaded from: [APKMirror - YouTube Music ${arch}]($dl_url)"
	fi
	patch_apk "$stock_apk" "$patched_apk" "${MUSIC_PATCHER_ARGS} -m ${RV_INTEGRATIONS_APK}"

	if [[ "$MUSIC_PATCHER_ARGS" != *"-e music-microg-support"* ]] && [[ "$MUSIC_PATCHER_ARGS" != *"--exclusive"* ]] || [[ "$MUSIC_PATCHER_ARGS" == *"-i music-microg-support"* ]]; then
		mv -f "$patched_apk" build
		echo "Built Music (no root) '${BUILD_DIR}/${patched_apk}'"
		return
	fi

	service_sh "com.google.android.apps.youtube.music"
	postfsdata_sh "com.google.android.apps.youtube.music"
	install_sh "com.google.android.apps.youtube.music" "$last_ver"

	local update_json="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/update/music-update-${arch}.json"
	if [ "$arch" = "$ARM64_V8A" ]; then
		local id="ytmusicrv-magisk"
	elif [ "$arch" = "$ARM_V7A" ]; then
		local id="ytmusicrv-arm-magisk"
	else
		echo "Wrong arch for prop: '$arch'"
		return
	fi
	module_prop "$id" \
		"YouTube Music ReVanced" \
		"$last_ver" \
		"mounts base.apk for YouTube Music ReVanced" \
		"$update_json"

	local output="music-revanced-magisk-v${last_ver}-${arch}.zip"
	local xdelta="${TEMP_DIR}/music-revanced-v${last_ver}.xdelta"
	get_xdelta "$stock_apk" "$patched_apk" "$xdelta"
	zip_module "$xdelta" "$output"
	echo "Built Music '${BUILD_DIR}/${output}'"
}

service_sh() {
	#shellcheck disable=SC2016
	local s='until [ "$(getprop sys.boot_completed)" = 1 ]; do
	sleep 1
done
BASEPATH=$(pm path PACKAGE | grep base | cut -d: -f2)
if [ "$BASEPATH" ]; then
	chcon u:object_r:apk_data_file:s0 $MODDIR/base.apk
	mount -o bind $MODDIR/base.apk $BASEPATH
fi'
	echo "${s//PACKAGE/$1}" >"${MODULE_TEMPLATE_DIR}/service.sh"
}

postfsdata_sh() {
	local s="cat /proc/mounts | grep PACKAGE | cut -d' ' -f2 | xargs -r umount -l"
	echo "${s//PACKAGE/$1}" >"${MODULE_TEMPLATE_DIR}/post-fs-data.sh"
}

install_sh() {
	#shellcheck disable=SC2016
	local s='ui_print ""
DUMP=$(dumpsys package PKGNAME)
MODULE_VER=MDVRSN
CUR_VER=$(echo "$DUMP" | grep versionName | head -n1 | cut -d= -f2)
if [ -z "$CUR_VER" ]; then
	abort "ERROR: PKGNAME is not installed!"
else	
	if [ "$MODULE_VER" != "$CUR_VER" ]; then
		ui_print "ERROR: PKGNAME version mismatch!"
		ui_print "  installed: ${CUR_VER}"
		ui_print "  module:    ${MODULE_VER}"
		abort
	else
		if [ "$ARCH" = "arm" ]; then
			ln -s $MODPATH/xdelta_arm $MODPATH/xdelta
		elif [ "$ARCH" = "arm64" ]; then
			ln -s $MODPATH/xdelta_aarch64 $MODPATH/xdelta
		else
			abort "ERROR: unsupported arch: ${ARCH}"
		fi
		chmod +x $xdelta

		am force-stop PKGNAME
		cat /proc/mounts | grep PKGNAME | cut -d" " -f2 | xargs -r umount -l

		ui_print "* Patching PKGNAME"
		BASEPATH=$(echo "$DUMP" | grep path | cut -d: -f2 | xargs)
		$MODPATH/xdelta -d -s $BASEPATH $MODPATH/rv.xdelta $MODPATH/base.apk || abort "Patching failed"
		ui_print "* Patching done"
		rm $MODPATH/*xdelta*

		chcon u:object_r:apk_data_file:s0 $MODPATH/base.apk
		mount -o bind $MODPATH/base.apk $BASEPATH || abort "Mounting failed"
		ui_print "* Mounted PKGNAME"
	fi
fi'
	s="${s//PKGNAME/$1}"
	echo "${s//MDVRSN/$2}" >"${MODULE_TEMPLATE_DIR}/common/install.sh"
}

module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=j-hc
description=${4}" >"${MODULE_TEMPLATE_DIR}/module.prop"

	if [ "$ENABLE_MAGISK_UPDATE" = true ]; then
		echo "updateJson=${5}" >>"${MODULE_TEMPLATE_DIR}/module.prop"
	fi
}
