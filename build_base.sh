#!/bin/bash

if [[ -z $ARCH || -z $LUNCH || -z $UBOOT_DEFCONFIG || -z $KERNEL_DEFCONFIG || -z $KERNEL_DTS ]];then
    echo "Missing some mandatory args, exit!"
    echo "ARCH=$ARCH"
    echo "LUNCH=$LUNCH"
    echo "UBOOT_DEFCONFIG=$UBOOT_DEFCONFIG"
    echo "KERNEL_DEFCONFIG=$KERNEL_DEFCONFIG"
    echo "KERNEL_DTS=$KERNEL_DTS"
    exit 1
fi

if [[ -n $BUILD_NUMBER ]]; then
  RELEASE_NAME=Tinker_Board-AndroidN-v"$BUILD_NUMBER"
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
#STUB_PATH="$(echo $STUB_PATH | tr '[:lower:]' '[:upper:]')"
if [[ -n $RELEASE_NAME ]]; then
  STUB_PATH=IMAGE/"$RELEASE_NAME"
  export STUB_PATH=$PROJECT_TOP/$STUB_PATH
  export STUB_PATCH_PATH=$STUB_PATH/PATCHES
fi

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

cd u-boot && make ARCHV=$ARCHV distclean && make ARCHV=$ARCHV $UBOOT_DEFCONFIG && make ARCHV=$ARCHV -j$JOBS && cd -
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
cd kernel && make ARCH=$ARCH distclean && make ARCH=$ARCH $KERNEL_DEFCONFIG && make ARCH=$ARCH $KERNEL_DTS.img -j$JOBS && cd -
if [ $? -eq 0 ]; then
    echo "Build kernel ok!"
else
    echo "Build kernel failed!"
    exit 1
fi
# build wifi ko
source device/rockchip/common/build_wifi_ko.sh


# build android
echo "start build android"
make installclean
if [ "$BUILD_OTA" = true ]; then
  echo "Will build the OTA package......."
  make BUILD_NUMBER=$BUILD_NUMBER ASUS_CSC_BUILD_NUMBER=WW_$BUILD_NUMBER ASUS_PROJECT_VERSION=$BUILD_NUMBER otapackage -j$JOBS
else
  make BUILD_NUMBER=$BUILD_NUMBER ASUS_CSC_BUILD_NUMBER=WW_$BUILD_NUMBER ASUS_PROJECT_VERSION=$BUILD_NUMBER -j$JOBS
fi

if [ $? -eq 0 ]; then
    echo "Build android ok!"
else
    echo "Build android failed!"
    exit 1
fi

# mkimage.sh
echo "make and copy android images"
if [ "$BUILD_OTA" = true ]; then
  INTERNAL_OTA_PACKAGE_OBJ_TARGET=$(find $OUT/obj/PACKAGING/target_files_intermediates/$TARGET_PRODUCT-target_files-*.zip)
  INTERNAL_OTA_PACKAGE_TARGET=$(find $OUT/$TARGET_PRODUCT-ota-*.zip)

  echo "generate ota package"
  ./mkimage.sh ota
  cp $INTERNAL_OTA_PACKAGE_TARGET $IMAGE_PATH/
  cp $INTERNAL_OTA_PACKAGE_OBJ_TARGET $IMAGE_PATH/

   # Build incremental update
  if [[ -n $PREVIOUS_TARGET_FILES ]]; then
    echo "Build incremental updates......."
    CURRENT_TARGET_FILES=$(find $IMAGE_PATH/$TARGET_PRODUCT-target_files-*.zip)
    CURRENT_TARGET_FILES_FILENAME=$(basename $CURRENT_TARGET_FILES)
    PREVIOUS_TARGET_FILES_FILENAME=$(basename $PREVIOUS_TARGET_FILES)
    ./build/tools/releasetools/ota_from_target_files -v -i $PREVIOUS_TARGET_FILES -p out/host/linux-x86 -k build/target/product/security/testkey $CURRENT_TARGET_FILES $IMAGE_PATH/Tinker_Board-AndroidN-Incremental-Update-${CURRENT_TARGET_FILES_FILENAME%.*}-from-${PREVIOUS_TARGET_FILES_FILENAME%.*}.zip
    if [ $? -eq 0 ]; then
      echo "Succeeded to build the incremental update."
    else
      echo "Failed to build the incremental update."
      exit 1
    fi
  fi
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

echo "Generate the image to be flashed via UMS mode......."
device/rockchip/common/programmer_image_tool -i $IMAGE_PATH/update.img -t emmc -o $IMAGE_PATH/
mv $IMAGE_PATH/out_image.bin $IMAGE_PATH/sdcard_full.img

if [[ -n $STUB_PATH ]]; then
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

  mv $STUB_PATH/IMAGES/sdcard_full.img $STUB_PATH/$RELEASE_NAME.img
  cd $STUB_PATH
  zip -j -m -T $RELEASE_NAME.zip $RELEASE_NAME.img
  sha256sum $RELEASE_NAME.zip > $RELEASE_NAME.zip.sha256sum
  cd -

  if [ "$BUILD_OTA" = true ]; then
    sha256sum $STUB_PATH/IMAGES/$TARGET_PRODUCT-target_files-$BUILD_NUMBER.zip > $STUB_PATH/IMAGES/$TARGET_PRODUCT-target_files-$BUILD_NUMBER.zip.sha256sum
    sha256sum $STUB_PATH/IMAGES/$TARGET_PRODUCT-ota-$BUILD_NUMBER.zip > $STUB_PATH/IMAGES/$TARGET_PRODUCT-ota-$BUILD_NUMBER.zip.sha256sum
  fi

  if [[ -n $PREVIOUS_TARGET_FILES ]]; then
    INCREMENTAL_UPDATE_FILE=($find $STUB_PATH/IMAGES/Tinker_Board-AndroidN-Incremental-Update-*-from-*.zip)
    sha256sum $INCREMENTAL_UPDATE_FILE > $INCREMENTAL_UPDATE_FILE.sha256sum
  fi
fi
