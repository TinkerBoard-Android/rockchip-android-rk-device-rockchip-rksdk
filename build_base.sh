#!/bin/bash

if [[ -z $ARCH || -z $LUNCH || -z $UBOOT_DEFCONFIG || -z $KERNEL_DEFCONFIG || -z $KERNEL_DTS || -z $RELEASE_NAME ]];then
    echo "Missing some mandatory args, exit!"
    echo "ARCH=$ARCH"
    echo "LUNCH=$LUNCH"
    echo "UBOOT_DEFCONFIG=$UBOOT_DEFCONFIG"
    echo "KERNEL_DEFCONFIG=$KERNEL_DEFCONFIG"
    echo "KERNEL_DTS=$KERNEL_DTS"
    echo "RELEASE_NAME=$RELEASE_NAME"
    exit 1
fi

source build/envsetup.sh >/dev/null && setpaths
lunch $LUNCH
TARGET_PRODUCT=`get_build_var TARGET_PRODUCT`

#set jdk version
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH
export CLASSPATH=.:$JAVA_HOME/lib:$JAVA_HOME/lib/tools.jar
# source environment and chose target product
DEVICE=`get_build_var TARGET_PRODUCT`
BUILD_VARIANT=`get_build_var TARGET_BUILD_VARIANT`
PACK_TOOL_DIR=RKTools/linux/Linux_Pack_Firmware
IMAGE_PATH=rockdev/Image-$TARGET_PRODUCT
export PROJECT_TOP=`gettop`

WIDEVINE_LEVEL=`get_build_var BOARD_WIDEVINE_OEMCRYPTO_LEVEL`

#lunch $DEVICE-$BUILD_VARIANT

#PLATFORM_VERSION=`get_build_var PLATFORM_VERSION`
#DATE=$(date  +%Y%m%d.%H%M)
#STUB_PATH=Image/"$KERNEL_DTS"_"$PLATFORM_VERSION"_"$DATE"_RELEASE_TEST
STUB_PATH=IMAGE/"$RELEASE_NAME"
#STUB_PATH="$(echo $STUB_PATH | tr '[:lower:]' '[:upper:]')"
export STUB_PATH=$PROJECT_TOP/$STUB_PATH
export STUB_PATCH_PATH=$STUB_PATH/PATCHES

# build uboot
echo "start build uboot"
if [ "$ARCH" = "arm64" ];then
    ARCHV=aarch64
elif [ "$ARCH" = "arm" ];then
    ARCHV=arm
else
    echo "Unknown arch, exit!"
    exit 1
fi

#cd u-boot && make ARCHV=$ARCHV distclean && make ARCHV=$ARCHV $UBOOT_DEFCONFIG && make ARCHV=$ARCHV -j$JOBS && cd -
if [ $? -eq 0 ]; then
    echo "Build uboot ok!"
else
    echo "Build uboot failed!"
    exit 1
fi
#trust: for rk3229 box WIDEVINE_LEVEL 1 must use ta trust
if [ "$WIDEVINE_LEVEL" = "1" ]; then
  if [ "$DEVICE" = "rk322x_box" ]; then
       mv u-boot/trust_with_ta.img u-boot/trust.img
       echo "WIDEVINE_LEVEL 1 use ta trust"
  fi
fi

# build kernel
echo "Start build kernel"
#cd kernel && make ARCH=$ARCH distclean && make ARCH=$ARCH $KERNEL_DEFCONFIG && make ARCH=$ARCH $KERNEL_DTS.img -j$JOBS && cd -
if [ $? -eq 0 ]; then
    echo "Build kernel ok!"
else
    echo "Build kernel failed!"
    exit 1
fi
# build wifi ko
#source device/rockchip/common/build_wifi_ko.sh

ASUS_CSC_BUILD_NUMBER=WW_"$BUILD_NUMBER"
ASUS_PROJECT_VERSION=$BUILD_NUMBER

# build android
echo "start build android"
make installclean
if [ "$BUILD_OTA" = true ] ; then
	echo "generate ota package"
	make BUILD_NUMBER=$BUILD_NUMBER ASUS_CSC_BUILD_NUMBER=$ASUS_CSC_BUILD_NUMBER ASUS_PROJECT_VERSION=$ASUS_PROJECT_VERSION otapackage -j$JOBS
else
	make BUILD_NUMBER=$BUILD_NUMBER ASUS_CSC_BUILD_NUMBER=$ASUS_CSC_BUILD_NUMBER ASUS_PROJECT_VERSION=$ASUS_PROJECT_VERSION -j$JOBS
fi

if [ $? -eq 0 ]; then
    echo "Build android ok!"
else
    echo "Build android failed!"
    exit 1
fi

# mkimage.sh
echo "make and copy android images"
if [ "$BUILD_OTA" = true ] ; then
    INTERNAL_OTA_PACKAGE_OBJ_TARGET=obj/PACKAGING/target_files_intermediates/$TARGET_PRODUCT-target_files-$BUILD_NUMBER.zip
    INTERNAL_OTA_PACKAGE_TARGET=$TARGET_PRODUCT-ota-$BUILD_NUMBER.zip
    echo "generate ota package"
    ./mkimage.sh ota
    cp $OUT/$INTERNAL_OTA_PACKAGE_TARGET $IMAGE_PATH/
    cp $OUT/$INTERNAL_OTA_PACKAGE_OBJ_TARGET $IMAGE_PATH/
	sha256sum $IMAGE_PATH/$TARGET_PRODUCT-target_files-$BUILD_NUMBER.zip > $IMAGE_PATH/$TARGET_PRODUCT-target_files-$BUILD_NUMBER.zip.sha256sum
	sha256sum $IMAGE_PATH/$TARGET_PRODUCT-ota-$BUILD_NUMBER.zip > $IMAGE_PATH/$TARGET_PRODUCT-ota-$BUILD_NUMBER.zip.sha256sum
else
	./mkimage.sh
fi

if [ $? -eq 0 ]; then
    echo "Make image ok!"
else
    echo "Make image failed!"
    exit 1
fi


mkdir -p $PACK_TOOL_DIR/rockdev/Image/
cp -f $IMAGE_PATH/* $PACK_TOOL_DIR/rockdev/Image/

echo "Make update.img"
cd $PACK_TOOL_DIR/rockdev && ./mkupdate.sh
if [ $? -eq 0 ]; then
    echo "Make update image ok!"
else
    echo "Make update image failed!"
    exit 1
fi
cd -

mv $PACK_TOOL_DIR/rockdev/update.img $IMAGE_PATH/
rm $PACK_TOOL_DIR/rockdev/Image -rf

mkdir -p $STUB_PATH

#Generate patches
echo "$PROJECT_TOP"
.repo/repo/repo forall -c "$PROJECT_TOP/device/rockchip/common/gen_patches_body.sh"

#Copy stubs
cp manifest.xml $STUB_PATH/manifest_$RELEASE_NAME.xml

mkdir -p $STUB_PATCH_PATH/kernel
cp kernel/.config $STUB_PATCH_PATH/kernel
cp kernel/vmlinux $STUB_PATCH_PATH/kernel

mkdir -p $STUB_PATH/IMAGES/
cp $IMAGE_PATH/* $STUB_PATH/IMAGES/
#Save build command info
echo "UBOOT:  defconfig: $UBOOT_DEFCONFIG" >> $STUB_PATH/build_cmd_info
echo "KERNEL: defconfig: $KERNEL_DEFCONFIG, dts: $KERNEL_DTS" >> $STUB_PATH/build_cmd_info
echo "ANDROID:$DEVICE-$BUILD_VARIANT" >> $STUB_PATH/build_cmd_info

# Delta package
if [ $TARGET_FILES_OLD ]; then
	echo "Start to build delta package..."
	TARGET_FILES_NEW=$STUB_PATH/IMAGES/$TARGET_PRODUCT-target_files-$BUILD_NUMBER.zip
	TARGET_FILES_FILENAME_NEW=$(basename $TARGET_FILES_NEW)
	TARGET_FILES_FILENAME_OLD=$(basename $TARGET_FILES_OLD)
	./build/tools/releasetools/ota_from_target_files -v -i $TARGET_FILES_OLD -p out/host/linux-x86 -k build/target/product/security/testkey $TARGET_FILES_NEW $STUB_PATH/IMAGES/Tinker_Board-AndroidN-Delta-${TARGET_FILES_FILENAME_NEW%.*}-from-${TARGET_FILES_FILENAME_OLD%.*}.zip
	if [ $? -eq 0 ]; then
	    echo "Succeed to generate the delta package."
	else
	    echo "Fail to generate the delta package."
	    exit 1
	fi
fi
