# Xiaomi 17 Ultra (nezha) TWRP Device Tree

This is my TWRP device tree for the Xiaomi 17 Ultra, codename `nezha`.

It is currently used to build TWRP 3.7.1 for Android 16 / HyperOS 3 based firmware.

The tree is still under active development. The main goal is to keep the recovery booting reliably while improving encryption support step by step.

## Current status

Working:

- TWRP boots into the UI
- Touchscreen works
- ADB works
- Reboot options work
- Bootloader reboot works
- Basic recovery environment is usable
- Recovery A/B layout is detected

Work in progress:

- Internal storage access
- FBE user data decryption
- Full Android 16 / HyperOS 3 crypto support

## Device information

| Name | Value |
|---|---|
| Device | Xiaomi 17 Ultra |
| Codename | nezha |
| Platform | SM8850 / canoe |
| Android base | Android 16 |
| Firmware base | HyperOS 3 |
| Recovery | TWRP 3.7.1 |

## Build instructions

Clone the device tree into your TWRP source tree:

    git clone -b Nezha https://github.com/kevte89/android_device_xiaomi_nezha_twrp.git device/xiaomi/nezha

Build the recovery image:

    source build/envsetup.sh
    lunch twrp_nezha-bp2a-eng
    mka recoveryimage -j$(nproc)

The output image will be created at:

    out/target/product/nezha/recovery.img

## Flash instructions

The Xiaomi 17 Ultra uses recovery A/B partitions.

Check the active slot first:

    fastboot getvar current-slot

If the active slot is `a`:

    fastboot flash recovery_a recovery.img
    fastboot reboot recovery

If the active slot is `b`:

    fastboot flash recovery_b recovery.img
    fastboot reboot recovery

## Notes

This tree is not final yet.

The current priority is a stable booting recovery base. Encryption and internal storage support are being worked on carefully without breaking the working recovery boot.

## Current development note

Current stable test state:

- TWRP boots reliably into the UI.
- Touch, ADB and basic recovery usage work.
- No-display-lock boot hang is fixed.
- FBE/User 0 decryption is still not complete.
- Goodix/eSE/GSEA/Weaver bringup is still under investigation.
- Bootable recovery changes are stored as patches under `patches/bootable-recovery/`.

This repository is still under active development.
