#!/system/bin/sh
# Stage secure-element TA firmware from recovery-owned storage before Mink starts.

LOG=/tmp/recovery.log
SRC=/sbin/nezha-firmware
FWROOT=/tmp/secure_element_fwroot
IMAGE="$FWROOT/image"

log_msg() {
    echo "secure-element-ta-setup: $1" >> "$LOG"
    log -t secure_element_ta_setup "$1" 2>/dev/null || true
}

link_ta_alias() {
    alias="$1"
    uuid="$2"

    found=0
    for src in "$IMAGE/$uuid".*; do
        [ -e "$src" ] || continue
        ext="${src##*.}"
        ln -sf "$(basename "$src")" "$IMAGE/$alias.$ext"
        found=1
    done

    if [ -e "$IMAGE/$uuid.mdt" ]; then
        ln -sf "$uuid.mdt" "$IMAGE/$alias.mbn"
        found=1
    fi

    if [ "$found" = 1 ]; then
        log_msg "alias $alias -> $uuid"
    else
        log_msg "alias $alias skipped, missing $uuid"
    fi
}

link_optional_mbn() {
    name="$1"

    for dir in "$IMAGE" /vendor/firmware/image /sbin/nezha-firmware/image; do
        [ -e "$dir/$name.mbn" ] || continue
        [ "$dir" = "$IMAGE" ] || ln -sf "$dir/$name.mbn" "$IMAGE/$name.mbn"
        log_msg "found optional $name.mbn at $dir/$name.mbn"
        return 0
    done

    log_msg "optional $name.mbn not present in Nezha stock/recovery source"
    return 1
}

log_msg "start"
rm -rf "$FWROOT"
mkdir -p "$IMAGE"
chmod 0755 "$FWROOT" "$IMAGE"

if [ -d "$SRC" ]; then
    cp -a "$SRC/." "$FWROOT/"
    mkdir -p "$IMAGE"
else
    log_msg "missing $SRC"
fi

# Nezha recovery source carries these stock TA UUID images. The names are
# visible inside the signed segments and match the Goodix/QSEE clients.
link_ta_alias eseservice 05B04A44-BF30-42DF-9E2F-B366B980ED19
link_ta_alias gpqese 32552B22-89FE-42B4-8A45-A0C4E2DB0326
link_ta_alias st_eseservice FD719D50-FFFB-11EB-9A03-0242AC130003

# Qualcomm QWES/TZSC/Haven token images are optional on Nezha stock. Do not
# synthesize them; just surface real files if the source tree or mounted vendor
# firmware provides them.
link_optional_mbn qwes
link_optional_mbn haventkn
link_optional_mbn tzsc

chmod -R 0755 "$FWROOT" 2>/dev/null || true
log_msg "image contents: $(ls "$IMAGE" 2>/dev/null | tr '\n' ' ')"
log_msg "done"
exit 0
