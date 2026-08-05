#!/system/bin/sh
MODDIR=${0%/*}

# 使用兼容模式

init_low_version() {

    # Android 13 or lower versions perform
    print_log "Use tmpfs $SYSTEM_CERT_DIR"
    print_log "Backup $SYSTEM_CERT_DIR"
    cp -u $SYSTEM_CERT_DIR/* $MODULE_CERT_DIR
    print_log "Backup $USER_CERT_DIR"
    cp -u $USER_CERT_DIR/* $MODULE_CERT_DIR

    move_custom_cert
    fix_user_permissions
    compatible
    selinux_context=$(ls -Zd $SYSTEM_CERT_DIR | awk '{print $1}')
    mount -t tmpfs tmpfs $SYSTEM_CERT_DIR
    print_log "mount $SYSTEM_CERT_DIR status:$?"

    cp -f $MODULE_CERT_DIR/* $SYSTEM_CERT_DIR

    print_log "Install $SYSTEM_CERT_DIR status:$?"
    fix_system_permissions $SYSTEM_CERT_DIR
    print_log "certificates installed"
    [ "$(getenforce)" = "Enforcing" ] || return 0
    default_selinux_context=u:object_r:system_security_cacerts_file:s0
    if [ -n "$selinux_context" ] && [ "$selinux_context" != "?" ]; then
        chcon -R $selinux_context $SYSTEM_CERT_DIR
    else
        chcon -R $default_selinux_context $SYSTEM_CERT_DIR
    fi
}


init_high_version() {

    SYSTEM_TEMP_DIR="${TEMP_DIR}_system"

    print_log "Use mount $TEMP_DIR"
    print_log "Use mount $SYSTEM_TEMP_DIR"
    mkdir -p "$TEMP_DIR" "$SYSTEM_TEMP_DIR"

    print_log "Backup $APEX_CONSCRYPT_DIR"
    cp -u $APEX_CONSCRYPT_DIR/* $MODULE_CERT_DIR
    print_log "Backup $SYSTEM_CERT_DIR"
    cp -u $SYSTEM_CERT_DIR/* $MODULE_CERT_DIR
    print_log "Backup $USER_CERT_DIR"
    cp -u $USER_CERT_DIR/* $MODULE_CERT_DIR

    move_custom_cert
    fix_user_permissions
    fix_system_permissions14 $MODULE_CERT_DIR
    compatible

    # 为 Conscrypt APEX 准备临时证书目录。
    mount -t tmpfs tmpfs "$TEMP_DIR"
    print_log "mount $TEMP_DIR status:$?"
    cp -f $MODULE_CERT_DIR/* "$TEMP_DIR"
    fix_system_permissions14 "$TEMP_DIR"
    set_selinux_context "$APEX_CONSCRYPT_DIR" "$TEMP_DIR"

    # 为仍读取旧路径的 Android 14+ 系统准备独立目录。
    mount -t tmpfs tmpfs "$SYSTEM_TEMP_DIR"
    print_log "mount $SYSTEM_TEMP_DIR status:$?"
    cp -f $MODULE_CERT_DIR/* "$SYSTEM_TEMP_DIR"
    fix_system_permissions "$SYSTEM_TEMP_DIR"
    set_selinux_context "$SYSTEM_CERT_DIR" "$SYSTEM_TEMP_DIR"

    # 标准 Android 14+ Conscrypt APEX 路径。
    if [ -d "$APEX_CONSCRYPT_DIR" ]; then
        mount --bind "$TEMP_DIR" "$APEX_CONSCRYPT_DIR"
        print_log "mount bind $TEMP_DIR $APEX_CONSCRYPT_DIR status:$?"
    fi

    # Issue #70：部分 Android 14/15 模拟器仍读取旧系统证书路径。
    if [ -d "$SYSTEM_CERT_DIR" ]; then
        mount --bind "$SYSTEM_TEMP_DIR" "$SYSTEM_CERT_DIR"
        print_log "mount bind $SYSTEM_TEMP_DIR $SYSTEM_CERT_DIR status:$?"
    fi

    # 处理所有带版本号的 Conscrypt APEX 目录。
    print_log "find system conscrypt directories"
    find /apex -type d -name 'com.android.conscrypt@*' 2>/dev/null |
    while IFS= read -r apex_dir; do
        target="$apex_dir/cacerts"
        [ -d "$target" ] || continue

        mount --bind "$TEMP_DIR" "$target"
        print_log "mount bind $TEMP_DIR $target status:$?"
    done

    # 将挂载同步到 PID 1、zygote 和 zygote64 的挂载命名空间。
    for pid in 1 $(pgrep zygote 2>/dev/null) $(pgrep zygote64 2>/dev/null); do
        [ -e "/proc/${pid}/ns/mnt" ] || continue

        if [ -d "$APEX_CONSCRYPT_DIR" ]; then
            nsenter --mount="/proc/${pid}/ns/mnt" -- \
                mount --bind "$TEMP_DIR" "$APEX_CONSCRYPT_DIR"
            print_log "pid=$pid mount bind $TEMP_DIR $APEX_CONSCRYPT_DIR status:$?"
        fi

        if [ -d "$SYSTEM_CERT_DIR" ]; then
            nsenter --mount="/proc/${pid}/ns/mnt" -- \
                mount --bind "$SYSTEM_TEMP_DIR" "$SYSTEM_CERT_DIR"
            print_log "pid=$pid mount bind $SYSTEM_TEMP_DIR $SYSTEM_CERT_DIR status:$?"
        fi

        find /apex -type d -name 'com.android.conscrypt@*' 2>/dev/null |
        while IFS= read -r apex_dir; do
            target="$apex_dir/cacerts"
            [ -d "$target" ] || continue

            nsenter --mount="/proc/${pid}/ns/mnt" -- \
                mount --bind "$TEMP_DIR" "$target"
            print_log "pid=$pid mount bind $TEMP_DIR $target status:$?"
        done
    done

    # 绑定挂载已经持有底层 tmpfs，可以清理临时入口。
    umount "$TEMP_DIR"
    print_log "umount $TEMP_DIR status:$?"
    rmdir "$TEMP_DIR" 2>/dev/null
    print_log "rmdir $TEMP_DIR status:$?"

    umount "$SYSTEM_TEMP_DIR"
    print_log "umount $SYSTEM_TEMP_DIR status:$?"
    rmdir "$SYSTEM_TEMP_DIR" 2>/dev/null
    print_log "rmdir $SYSTEM_TEMP_DIR status:$?"

    print_log "certificates installed"
}