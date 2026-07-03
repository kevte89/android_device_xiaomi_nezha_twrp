#!/system/bin/sh
# Record the runtime secure-element firmware view after the bind mount.

LOG=/tmp/recovery.log
IMAGE=/vendor/firmware_mnt/image

log_msg() {
    echo "secure-element-followup: $1" >> "$LOG"
    log -t secure_element_followup "$1" 2>/dev/null || true
}

log_msg "start"
mkdir -p "$IMAGE"

for name in qwes haventkn tzsc eseservice gpqese st_eseservice; do
    if ls "$IMAGE/$name".* >/dev/null 2>&1; then
        log_msg "$name visible: $(ls "$IMAGE/$name".* 2>/dev/null | tr '\n' ' ')"
    else
        log_msg "$name not visible"
    fi
done

log_msg "done"
exit 0
