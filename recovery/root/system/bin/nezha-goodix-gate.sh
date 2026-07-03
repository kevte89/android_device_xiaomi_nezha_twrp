#!/system/bin/sh
# Start the Xiaomi 17 Ultra Goodix eSE/Weaver chain used by the stock system.
# The same recovery image is used for both nezha hardware variants.  Pick a
# conservative startup route at runtime so 5.9.0 and 5.9.7 do not race the eSE
# stack in the same way.

LOG=/tmp/recovery.log
TMPROOT=/tmp/nezha-goodix
TMPLOG=$TMPROOT/log
FWROOT=/tmp/secure_element_fwroot
FWMNT=/vendor/firmware_mnt
FWIMAGE=$FWMNT/image
SE_UUID=7C2FC71B-A45E-2FA1-ACF3-42EBC235C082
FWROOT_UUID_B00=$FWROOT/image/$SE_UUID.b00
FWROOT_ALIAS_B00=$FWROOT/image/eseservice.b00
SE_UUID_B00=$FWIMAGE/$SE_UUID.b00
SE_ALIAS_B00=$FWIMAGE/eseservice.b00
ST_NFC_DEV=/dev/st21nfc
ST_ESE_GPIO_DEV=/dev/st54spi_gpio
ST_NFC_CONF=/odm/etc/libnfc-hal-st.conf
ST_NFC_CONF_VENDOR=/vendor/odm/etc/libnfc-hal-st.conf
ST54_CONF=/odm/etc/st54l_conf.txt
ST54_CONF_VENDOR=/vendor/odm/etc/st54l_conf.txt
ST54_FW=/odm/firmware/st54l_fw.bin
ST54_FW_VENDOR=/vendor/odm/firmware/st54l_fw.bin
GSEA_COS_STATE=/sys/se/cos_update_state
GSEA_STRONGBOX_STATE=/sys/se/strongbox_io_state
WEAVER_AIDL_SERVICE=android.hardware.weaver.IWeaver/default

log_line_count() {
    wc -l "$LOG" 2>/dev/null | awk '{print $1}'
}

log_msg() {
    echo "nezha-goodix-gate: $1" >> "$LOG"
    echo "nezha-goodix-gate: $1" >> "$TMPLOG" 2>/dev/null || true
    log -t nezha_goodix_gate "$1" 2>/dev/null || true
}

wait_stable_running() {
    name="$1"
    stable_needed="$2"
    limit="$3"
    stable=0
    i=0
    while [ "$i" -lt "$limit" ]; do
        if [ "$(getprop "init.svc.$name")" = "running" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge "$stable_needed" ] && return 0
        else
            stable=0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

wait_socket() {
    path="$1"
    limit="$2"
    i=0
    while [ "$i" -lt "$limit" ]; do
        [ -S "$path" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

wait_path() {
    path="$1"
    limit="$2"
    i=0
    while [ "$i" -lt "$limit" ]; do
        [ -e "$path" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

module_loaded() {
    name="$1"
    grep -q "^$name " /proc/modules 2>/dev/null
}

load_module_once() {
    module="$1"
    name="${module%.ko}"
    name="$(echo "$name" | tr '-' '_')"

    if module_loaded "$name"; then
        log_msg "$module already loaded"
        return 0
    fi

    for dir in /vendor/lib/modules /vendor_dlkm/lib/modules /lib/modules; do
        path="$dir/$module"
        if [ -f "$path" ]; then
            log_msg "loading delayed FBE module $path"
            if insmod "$path" >> "$LOG" 2>&1; then
                return 0
            fi
            log_msg "failed to load delayed FBE module $path"
            setprop twrp.nezha.goodix_gate_error "module_${name}_load_failed"
            return 1
        fi
    done

    log_msg "delayed FBE module $module is missing"
    setprop twrp.nezha.goodix_gate_error "module_${name}_missing"
    return 1
}

load_st54se_modules_after_qsee() {
    if ! load_module_once stm_st54se_gpio.ko; then
        return 1
    fi
    if ! load_module_once stm_nfc_i2c.ko; then
        return 1
    fi
    return 0
}

prepare_qseecomd_devices() {
    chown system:drmrpc /dev/smcinvoke /dev/qsee_ipc_irq_spss /dev/dma_heap/qcom,qseecom 2>/dev/null || true
    chmod 0660 /dev/smcinvoke /dev/qsee_ipc_irq_spss /dev/dma_heap/qcom,qseecom 2>/dev/null || true
    log_msg "qsee devices: smcinvoke=$([ -e /dev/smcinvoke ] && ls -l /dev/smcinvoke || echo missing) qsee_irq=$([ -e /dev/qsee_ipc_irq_spss ] && ls -l /dev/qsee_ipc_irq_spss || echo missing) heap=$([ -e /dev/dma_heap/qcom,qseecom ] && ls -l /dev/dma_heap/qcom,qseecom || echo missing)"
}

wait_qseecomd_usable() {
    stable_needed="$1"
    limit="$2"

    prepare_qseecomd_devices
    start vendor.qseecomd
    if ! wait_stable_running vendor.qseecomd "$stable_needed" "$limit"; then
        setprop twrp.nezha.goodix_gate_error vendor_qseecomd_not_stable
        log_msg "vendor.qseecomd did not stay running"
        return 1
    fi
    if ! wait_path /dev/dma_heap/qcom,qseecom 5; then
        setprop twrp.nezha.goodix_gate_error qseecom_dma_heap_missing
        log_msg "/dev/dma_heap/qcom,qseecom is missing after qseecomd start"
        return 1
    fi
    prepare_qseecomd_devices
    if [ ! -r /dev/dma_heap/qcom,qseecom ]; then
        setprop twrp.nezha.goodix_gate_error qseecom_dma_heap_unusable
        log_msg "/dev/dma_heap/qcom,qseecom is not readable after qseecomd start"
        return 1
    fi

    log_msg "vendor.qseecomd stable and qseecom dma heap usable"
    return 0
}

log_st54se_view() {
    log_msg "$1: st21nfc=$([ -e "$ST_NFC_DEV" ] && ls -l "$ST_NFC_DEV" || echo missing) st54spi_gpio=$([ -e "$ST_ESE_GPIO_DEV" ] && ls -l "$ST_ESE_GPIO_DEV" || echo missing) st_hal_conf=$([ -f "$ST_NFC_CONF" ] || [ -f "$ST_NFC_CONF_VENDOR" ] && echo visible || echo missing) st54_conf=$([ -f "$ST54_CONF" ] || [ -f "$ST54_CONF_VENDOR" ] && echo visible || echo missing) st54_fw=$([ -f "$ST54_FW" ] || [ -f "$ST54_FW_VENDOR" ] && echo visible || echo missing)"
}

ensure_st54se_path() {
    wait_path "$ST_NFC_DEV" 10 || true
    wait_path "$ST_ESE_GPIO_DEV" 5 || true
    log_st54se_view "$1"

    if [ ! -e "$ST_NFC_DEV" ]; then
        setprop twrp.nezha.goodix_gate_error st21nfc_missing
        return 1
    fi
    if [ ! -e "$ST_ESE_GPIO_DEV" ]; then
        setprop twrp.nezha.goodix_gate_error st54spi_gpio_missing
        return 1
    fi
    if { [ ! -f "$ST_NFC_CONF" ] && [ ! -f "$ST_NFC_CONF_VENDOR" ]; } || \
       { [ ! -f "$ST54_CONF" ] && [ ! -f "$ST54_CONF_VENDOR" ]; } || \
       { [ ! -f "$ST54_FW" ] && [ ! -f "$ST54_FW_VENDOR" ]; }; then
        setprop twrp.nezha.goodix_gate_error st54se_stock_files_missing
        return 1
    fi

    chmod 0660 "$ST_NFC_DEV" "$ST_ESE_GPIO_DEV" 2>/dev/null || true
    chown nfc:nfc "$ST_NFC_DEV" 2>/dev/null || true
    chown system:system "$ST_ESE_GPIO_DEV" 2>/dev/null || true
    return 0
}

log_gsea_sysfs_view() {
    log_msg "$1: cos_update_state=$([ -e "$GSEA_COS_STATE" ] && cat "$GSEA_COS_STATE" 2>/dev/null || echo missing) strongbox_io_state=$([ -e "$GSEA_STRONGBOX_STATE" ] && cat "$GSEA_STRONGBOX_STATE" 2>/dev/null || echo missing)"
}

log_gsea_sysfs_missing_diag() {
    {
        echo "nezha-goodix-gate: $1: /proc/modules FBE view"
        cat /proc/modules 2>/dev/null | grep -E "gsim|spi_msm|spi-msm|stm|smcinvoke|qsee" || true
        echo "nezha-goodix-gate: $1: /sys/se view"
        ls -ld /sys/se /sys/se/* 2>/dev/null || true
        echo "nezha-goodix-gate: $1: dmesg FBE view"
        dmesg 2>/dev/null | grep -Ei "gsim|st54|st21|secure hw|Peripheral not found|smcinvoke|qsee" | tail -120 || true
    } >> "$LOG"
    {
        echo "nezha-goodix-gate: $1: /proc/modules FBE view"
        cat /proc/modules 2>/dev/null | grep -E "gsim|spi_msm|spi-msm|stm|smcinvoke|qsee" || true
        echo "nezha-goodix-gate: $1: /sys/se view"
        ls -ld /sys/se /sys/se/* 2>/dev/null || true
        echo "nezha-goodix-gate: $1: dmesg FBE view"
        dmesg 2>/dev/null | grep -Ei "gsim|st54|st21|secure hw|Peripheral not found|smcinvoke|qsee" | tail -120 || true
    } >> "$TMPLOG" 2>/dev/null || true
}

ensure_gsea_sysfs() {
    wait_path "$GSEA_COS_STATE" 5 || true
    wait_path "$GSEA_STRONGBOX_STATE" 5 || true

    if [ ! -e "$GSEA_COS_STATE" ] || [ ! -e "$GSEA_STRONGBOX_STATE" ]; then
        log_gsea_sysfs_view "$1"
        log_msg "$1: GSEA sysfs state is missing; stm_st54se_gpio did not publish /sys/se"
        log_gsea_sysfs_missing_diag "$1"
        setprop twrp.nezha.goodix_gate_error gsea_sysfs_missing
        return 1
    fi

    chmod 0666 "$GSEA_COS_STATE" "$GSEA_STRONGBOX_STATE" 2>/dev/null || true
    log_gsea_sysfs_view "$1"
    return 0
}

goodix_errors_since() {
    start_line="$1"
    [ -z "$start_line" ] && start_line=1
    sed -n "${start_line},\$p" "$LOG" 2>/dev/null | grep -Eqi \
        "HalToHalTransport: Not connected to eSE Service|Failed to open Logical Channel|No Goodix Chip found|T=1 protocol initialize failed|not receive 0x12|spi read failed|software reset failed|GetSlots Failed|Weaver AIDL getConfig Status\\(-8\\)"
}

weaver_binder_registered() {
    if [ ! -x /system/bin/service ]; then
        log_msg "cannot verify $WEAVER_AIDL_SERVICE: /system/bin/service missing"
        setprop twrp.nezha.goodix_gate_error service_check_missing
        return 1
    fi

    /system/bin/service check "$WEAVER_AIDL_SERVICE" > "$TMPROOT/weaver-service-check" 2>&1 || true
    if grep -Eqi "not found|null|Can't find|not declared" "$TMPROOT/weaver-service-check"; then
        log_msg "$WEAVER_AIDL_SERVICE not registered: $(cat "$TMPROOT/weaver-service-check" 2>/dev/null)"
        setprop twrp.nezha.goodix_gate_error weaver_binder_not_registered
        return 1
    fi

    log_msg "$WEAVER_AIDL_SERVICE registered: $(cat "$TMPROOT/weaver-service-check" 2>/dev/null)"
    return 0
}

validate_weaver_ready() {
    start_line="$1"

    if ! wait_stable_running secure_element_hal_service 2 6; then
        setprop twrp.nezha.goodix_gate_error secure_element_hal_lost_after_weaver
        log_msg "secure_element_hal_service is not stable after Weaver start"
        return 1
    fi
    if ! weaver_binder_registered; then
        return 1
    fi
    if goodix_errors_since "$start_line"; then
        setprop twrp.nezha.goodix_gate_error goodix_transport_error_after_weaver
        log_msg "Goodix/eSE transport errors appeared after Weaver start; not marking ready"
        return 1
    fi

    return 0
}

start_minkipcbinder_oneshot() {
    limit="$1"

    if ! wait_socket /dev/socket/ssgtzd "$limit"; then
        setprop twrp.nezha.goodix_gate_error ssgtzd_socket_missing
        log_msg "vendor.minkdaemon did not publish /dev/socket/ssgtzd"
        return 1
    fi
    if ! wait_socket /dev/socket/hlos_mink_opener "$limit"; then
        setprop twrp.nezha.goodix_gate_error hlos_mink_opener_socket_missing
        log_msg "vendor.minkdaemon did not publish /dev/socket/hlos_mink_opener"
        return 1
    fi

    log_msg "starting minkipcbinder-service after vendor.minkdaemon sockets; stock service is disabled oneshot"
    start minkipcbinder-service
    sleep 2
    state="$(getprop init.svc.minkipcbinder-service)"
    setprop twrp.nezha.minkipcbinder_state "$state"
    case "$state" in
        running|stopped|"")
            log_msg "minkipcbinder-service oneshot accepted state=$state"
            return 0
            ;;
        *)
            setprop twrp.nezha.goodix_gate_error minkipcbinder_oneshot_bad_state
            log_msg "minkipcbinder-service unexpected oneshot state=$state"
            return 1
            ;;
    esac
}

start_ssgqmigd_service() {
    stable_needed="$1"
    limit="$2"

    stop ssgqmigd
    killall ssgqmigd 2>/dev/null || true
    killall ssgqmigd64 2>/dev/null || true
    rm -f /dev/socket/ssgqmig 2>/dev/null || true

    log_msg "starting ssgqmigd init service with ANDROID_SOCKET_ssgqmig"
    start ssgqmigd

    if ! wait_socket /dev/socket/ssgqmig "$limit"; then
        setprop twrp.nezha.goodix_gate_error ssgqmig_socket_missing
        log_msg "ssgqmigd did not publish /dev/socket/ssgqmig"
        return 1
    fi

    if ! wait_stable_running ssgqmigd "$stable_needed" "$limit"; then
        setprop twrp.nezha.goodix_gate_error ssgqmigd_not_stable
        log_msg "ssgqmigd did not stay running"
        return 1
    fi

    setprop twrp.nezha.ssgqmigd_state "$(getprop init.svc.ssgqmigd)"
    log_msg "ssgqmigd ready state=$(getprop init.svc.ssgqmigd) socket=/dev/socket/ssgqmig"
    return 0
}

detect_route() {
    model="$(getprop ro.product.model)"
    hwver="$(getprop ro.boot.hwversion)"
    vbstate="$(getprop ro.boot.verifiedbootstate)"
    fp="$(getprop ro.vendor.build.fingerprint)"

    route=fallback
    case "$model:$hwver" in
        *25128PNA1C*|*:5.9.7*) route=leica_597 ;;
        *2512BPNDAC*|*:5.9.0*|*:5.19.0*) route=normal_590 ;;
    esac

    setprop twrp.nezha.model "$model"
    setprop twrp.nezha.hwversion "$hwver"
    setprop twrp.nezha.verifiedbootstate "$vbstate"
    setprop twrp.nezha.crypto_route "$route"
    log_msg "route=$route model=$model hwversion=$hwver vbstate=$vbstate fp=$fp"
}

reset_goodix_services() {
    stop goodix_weaver_hal_service
    stop secure_element_hal_service
    stop vendor.qwesd
    stop ssgqmigd
    stop minkipcbinder-service
    stop vendor.minkdaemon
    killall android.hardware.weaver-service-goodix-recovery 2>/dev/null || true
    killall android.hardware.secure_element-service-goodix-recovery 2>/dev/null || true
    killall qwesd 2>/dev/null || true
    killall ssgqmigd 2>/dev/null || true
    killall ssgqmigd64 2>/dev/null || true
    killall hlosminkdaemon 2>/dev/null || true
    killall vendor.qti.hardware.minkipcbinder@1.0-service 2>/dev/null || true
    rm -f /dev/socket/ssgqmig /dev/socket/ssgtzd /dev/socket/hlos_mink_opener 2>/dev/null || true
}

prepare_tmp_state() {
    mkdir -p "$TMPROOT" "$TMPROOT/data" "$TMPROOT/persist" "$TMPROOT/logs"
    chmod 0700 "$TMPROOT" "$TMPROOT/data" "$TMPROOT/persist" "$TMPROOT/logs"
    rm -rf /tmp/SELog* /tmp/goodix* 2>/dev/null || true

    # The Goodix secure-element HAL unconditionally scans its stock data/log
    # directory and aborts on a missing path before Weaver can start.
    if [ -d /data/vendor ] || [ -d /data/media ]; then
        mkdir -p /data/vendor/goodix/secure_element
        mkdir -p /data/vendor/secure_element
        mkdir -p /mnt/vendor/persist/goodix /mnt/vendor/persist/data
        chown -R secure_element:secure_element /data/vendor/goodix 2>/dev/null || \
            chown -R system:system /data/vendor/goodix 2>/dev/null || true
        chown -R secure_element:secure_element /data/vendor/secure_element 2>/dev/null || \
            chown -R system:system /data/vendor/secure_element 2>/dev/null || true
        chmod -R 0777 /data/vendor/goodix /data/vendor/secure_element 2>/dev/null || true
        restorecon -RFv /data/vendor/goodix /data/vendor/secure_element \
            /mnt/vendor/persist/goodix /mnt/vendor/persist/data \
            >> "$LOG" 2>&1 || true
    fi
}

secure_element_firmware_visible() {
    [ -f "$SE_UUID_B00" ] && [ -f "$SE_ALIAS_B00" ]
}

secure_element_fwroot_ready() {
    [ -f "$FWROOT_UUID_B00" ] && [ -f "$FWROOT_ALIAS_B00" ]
}

log_secure_element_firmware_view() {
    log_msg "$1: fwroot_uuid=$([ -f "$FWROOT_UUID_B00" ] && echo visible || echo missing) fwroot_alias=$([ -f "$FWROOT_ALIAS_B00" ] && echo visible || echo missing) vendor_uuid=$([ -f "$SE_UUID_B00" ] && echo visible || echo missing) vendor_alias=$([ -f "$SE_ALIAS_B00" ] && echo visible || echo missing) fwmnt_mounted=$(grep -q " $FWMNT " /proc/mounts && echo yes || echo no)"
}

rebind_secure_element_firmware() {
    /system/bin/secure-element-ta-setup.sh
    mkdir -p "$FWROOT" "$FWROOT/image" "$FWMNT"
    chmod 0755 "$FWROOT" "$FWROOT/image" "$FWMNT" 2>/dev/null || true

    if ! secure_element_fwroot_ready; then
        log_secure_element_firmware_view "fwroot missing after setup"
        return 1
    fi

    while grep -q " $FWMNT " /proc/mounts; do
        umount "$FWMNT" 2>/dev/null || break
    done

    mount -o bind "$FWROOT" "$FWMNT" 2>/dev/null || \
        mount none "$FWROOT" "$FWMNT" bind 2>/dev/null || {
            log_secure_element_firmware_view "bind mount failed"
            return 1
        }
    /system/bin/secure-element-followup.sh
    secure_element_firmware_visible
}

ensure_secure_element_firmware() {
    reason="$1"

    if secure_element_firmware_visible; then
        log_secure_element_firmware_view "$reason already visible"
        return 0
    fi

    log_secure_element_firmware_view "$reason not visible, rebuilding bind mount"
    rebind_secure_element_firmware || true

    if secure_element_firmware_visible; then
        log_secure_element_firmware_view "$reason visible after rebind"
        return 0
    fi

    log_secure_element_firmware_view "$reason still missing after rebind"
    setprop twrp.nezha.goodix_gate_error secure_element_firmware_not_visible
    return 1
}

setprop twrp.nezha.goodix_gate_started 1
setprop twrp.nezha.goodix_gate_error ""
setprop twrp.nezha.weaver_ready 0
prepare_tmp_state
detect_route
log_msg "start"
GATE_LOG_START="$(log_line_count)"

# PRODUCT_COPY_FILES can normalize rootfs overlay executables to 0644.
# Restore executable mode before init launches the stable /sbin copies.
chmod 0755 /sbin/android.hardware.secure_element-service-goodix-recovery
chmod 0755 /sbin/android.hardware.weaver-service-goodix-recovery

# qseecomd and Mink must be started only after smcinvoke_dlkm is loaded and
# /dev/smcinvoke has usable ownership. Their stock early-boot attempt can race
# recovery's late module loader and leave the TA opener in a broken state.
reset_goodix_services
if ! ensure_secure_element_firmware before_secure_element_chain; then
    log_msg "secure-element firmware is not visible under $FWIMAGE; not starting Goodix chain"
    exit 0
fi

case "$(getprop twrp.nezha.crypto_route)" in
    normal_590)
        # 5.9.0 has been observed to report "running" before the eSE pair is
        # actually usable. Give QSEE/Mink and the Goodix pair more settle time.
        qsee_stable=3
        qsee_limit=25
        mink_stable=3
        mink_limit=25
        minkipc_limit=20
        qwes_stable=3
        qwes_limit=25
        qti_se_stable=4
        qti_se_limit=35
        ssg_stable=3
        ssg_limit=25
        se_stable=4
        se_limit=35
        weaver_stable=5
        weaver_limit=14
        weaver_attempts=7
        settle_before_goodix=3
        retry_sleep=3
        ;;
    leica_597)
        qsee_stable=2
        qsee_limit=15
        mink_stable=2
        mink_limit=15
        minkipc_limit=15
        qwes_stable=2
        qwes_limit=15
        qti_se_stable=2
        qti_se_limit=20
        ssg_stable=2
        ssg_limit=15
        se_stable=2
        se_limit=20
        weaver_stable=3
        weaver_limit=8
        weaver_attempts=5
        settle_before_goodix=1
        retry_sleep=2
        ;;
    *)
        qsee_stable=3
        qsee_limit=25
        mink_stable=3
        mink_limit=25
        minkipc_limit=20
        qwes_stable=3
        qwes_limit=25
        qti_se_stable=3
        qti_se_limit=30
        ssg_stable=3
        ssg_limit=25
        se_stable=3
        se_limit=30
        weaver_stable=4
        weaver_limit=12
        weaver_attempts=6
        settle_before_goodix=2
        retry_sleep=3
        ;;
esac

stop vendor.qseecomd
stop minkipcbinder-service
stop vendor.minkdaemon
stop vendor.qwesd
stop ssgqmigd
rm -f /dev/socket/ssgqmig /dev/socket/ssgtzd /dev/socket/hlos_mink_opener 2>/dev/null || true
sleep 1
if ! wait_qseecomd_usable "$qsee_stable" "$qsee_limit"; then
    exit 0
fi

if ! load_st54se_modules_after_qsee; then
    log_msg "ST54SE/NFC modules could not be loaded after qseecomd became stable"
    exit 0
fi
if ! ensure_st54se_path after_qseecomd_stable; then
    log_msg "ST54SE NFC/eSE path is incomplete after delayed module load; not starting Goodix chain"
    exit 0
fi
if ! ensure_gsea_sysfs after_qseecomd_stable; then
    log_msg "GSEA sysfs state is incomplete after delayed ST54/NFC load; not starting Goodix chain"
    exit 0
fi

if ! start_ssgqmigd_service "$ssg_stable" "$ssg_limit"; then
    exit 0
fi

# Goodix uses libGPMTEEC_vendor through the HLOS Mink opener. Keep the
# dependency explicit, and start HLOS Mink only after ssgqmigd has published
# /dev/socket/ssgqmig. Recovery logs showed sec_channel failures in
# hlosminkdaemon when Mink initialized before the SSG QMIG socket was ready.
if ! ensure_secure_element_firmware before_vendor_minkdaemon; then
    log_msg "secure-element firmware disappeared before vendor.minkdaemon"
    exit 0
fi
start vendor.minkdaemon
if ! wait_stable_running vendor.minkdaemon "$mink_stable" "$mink_limit"; then
    setprop twrp.nezha.goodix_gate_error vendor_minkdaemon_not_stable
    log_msg "vendor.minkdaemon did not stay running"
    exit 0
fi

if ! start_minkipcbinder_oneshot "$minkipc_limit"; then
    exit 0
fi

if ! ensure_secure_element_firmware before_vendor_qwesd; then
    log_msg "secure-element firmware disappeared before vendor.qwesd"
    exit 0
fi
start vendor.qwesd
if ! wait_stable_running vendor.qwesd "$qwes_stable" "$qwes_limit"; then
    setprop twrp.nezha.goodix_gate_error vendor_qwesd_not_stable
    log_msg "vendor.qwesd did not stay running"
    exit 0
fi

if ! ensure_secure_element_firmware before_vendor_secure_element; then
    log_msg "secure-element firmware disappeared before vendor.secure_element"
    exit 0
fi
start vendor.secure_element
if ! wait_stable_running vendor.secure_element "$qti_se_stable" "$qti_se_limit"; then
    setprop twrp.nezha.goodix_gate_error vendor_secure_element_not_stable
    log_msg "vendor.secure_element did not stay running"
    exit 0
fi

sleep "$settle_before_goodix"

if ! ensure_secure_element_firmware before_secure_element_hal_service; then
    log_msg "secure-element firmware disappeared before secure_element_hal_service"
    exit 0
fi
if ! ensure_st54se_path before_secure_element_hal_service; then
    log_msg "ST54SE NFC/eSE path disappeared before secure_element_hal_service"
    exit 0
fi
if ! ensure_gsea_sysfs before_secure_element_hal_service; then
    log_msg "GSEA sysfs state disappeared before secure_element_hal_service"
    exit 0
fi
start secure_element_hal_service
if ! wait_stable_running secure_element_hal_service "$se_stable" "$se_limit"; then
    setprop twrp.nezha.goodix_gate_error secure_element_hal_not_stable
    log_msg "secure_element_hal_service did not stay running"
    exit 0
fi

attempt=1
while [ "$attempt" -le "$weaver_attempts" ]; do
    setprop twrp.nezha.goodix_gate_attempt "$attempt"
    log_msg "start goodix_weaver_hal_service attempt $attempt"
    ATTEMPT_LOG_START="$(log_line_count)"
    if ! ensure_secure_element_firmware "before_goodix_weaver_hal_service_attempt_$attempt"; then
        log_msg "secure-element firmware disappeared before goodix_weaver_hal_service"
        exit 0
    fi
    if ! ensure_gsea_sysfs "before_goodix_weaver_hal_service_attempt_$attempt"; then
        log_msg "GSEA sysfs state disappeared before goodix_weaver_hal_service"
        exit 0
    fi
    start goodix_weaver_hal_service
    if wait_stable_running goodix_weaver_hal_service "$weaver_stable" "$weaver_limit"; then
        sleep 2
        if validate_weaver_ready "$ATTEMPT_LOG_START"; then
            setprop twrp.nezha.weaver_ready 1
            log_msg "Goodix eSE2 transport and Weaver service registered route=$(getprop twrp.nezha.crypto_route)"
            exit 0
        fi
    fi
    stop goodix_weaver_hal_service
    killall android.hardware.weaver-service-goodix-recovery 2>/dev/null || true
    sleep "$retry_sleep"
    attempt=$((attempt + 1))
done

if [ "$(getprop init.svc.goodix_weaver_hal_service)" != "running" ]; then
    setprop twrp.nezha.goodix_gate_error goodix_weaver_hal_not_stable
    log_msg "goodix_weaver_hal_service did not stay running"
fi

exit 0
