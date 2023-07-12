wait_for_shell() {
    if is_unix; then
        try --max 24 --delay 5 rdctl shell test -f /var/run/lima-boot-done
        assert_success
        # wait until sshfs mounts are done
        try --max 12 --delay 5 rdctl shell test -d "$HOME/.rd"
        assert_success
    fi
    rdctl shell sync
}

pkill_by_path() {
    local arg
    arg=$(readlink -f "$1")
    if [[ -n $arg ]]; then
        pkill -f "$arg"
    fi
}

windows_cleanup() {
    # Fixed in WSL 0.64.0, however below is a workaround for windows10
    # https://github.com/microsoft/WSL/releases/tag/0.64.0
    export WSL_UTF8=1
    WSLENV="$WSLENV":WSL_UTF8
    # match rancher-desktop and not rancher-desktop-data
    if is_windows && wsl_exe -l -v | grep -Po '(?<=^| )rancher-desktop(?!-data(?=\b|$))'; then
        run wsl_exe --distribution rancher-desktop ip link delete docker0
        run wsl_exe --distribution rancher-desktop ip link delete nerdctl0

        wsl_exe --distribution rancher-desktop iptables -F
        wsl_exe --distribution rancher-desktop iptables -L | awk '/^Chain CNI/ {print $2}' | xargs -I{} iptables -X {}
    fi
}

factory_reset() {
    if [ "$BATS_TEST_NUMBER" -gt 1 ]; then
        capture_logs
    fi

    if using_npm_run_dev; then
        if is_unix; then
            run rdctl shutdown
            run pkill_by_path "$PATH_REPO_ROOT/node_modules"
            run pkill_by_path "$PATH_RESOURCES"
            run pkill_by_path "$LIMA_HOME"
        else
            # TODO: kill `npm run dev` instance on Windows
            true
        fi
    fi
    windows_cleanup
    rdctl factory-reset
}

# Turn `rdctl start` arguments into `npm run dev` arguments
apify_arg() {
    # TODO this should be done via autogenerated code from command-api.yaml
    perl -w - "$1" <<'EOF'
# don't modify the value part after the first '=' sign
($_, my $value) = split /=/, shift, 2;
if (/^--/) {
    # turn "--virtual-machine.memory-in-gb" into "--virtualMachine.memoryInGb"
    s/(\w)-(\w)/$1\U$2/g;
    # fixup acronyms
    s/memoryInGb/memoryInGB/;
    s/numberCpus/numberCPUs/;
    s/socketVmnet/socketVMNet/;
    s/--wsl/--WSL/;
}
print;
print "=$value" if $value;
EOF
}

start_container_engine() {
    local args=(
        --application.debug
        --application.updater.enabled=false
        --kubernetes.enabled=false
    )
    if [ -n "$RD_CONTAINER_ENGINE" ]; then
        args+=(--container-engine.name="$RD_CONTAINER_ENGINE")
    fi
    if is_unix; then
        args+=(
            --application.admin-access=false
            --application.path-management-strategy rcfiles
            --virtual-machine.memory-in-gb 6
            --experimental.virtual-machine.mount.type="$RD_MOUNT_TYPE"
        )
    fi
    if [ "$RD_MOUNT_TYPE" = "9p" ]; then
        args+=(
            --experimental.virtual-machine.mount.9p.cache-mode="$RD_9P_CACHE_MODE"
            --experimental.virtual-machine.mount.9p.msize-in-kib="$RD_9P_MSIZE"
            --experimental.virtual-machine.mount.9p.protocol-version="$RD_9P_PROTOCOL_VERSION"
            --experimental.virtual-machine.mount.9p.security-model="$RD_9P_SECURITY_MODEL"
        )
    fi
    if using_networking_tunnel; then
        args+=(--experimental.virtual-machine.networking-tunnel)
    fi
    if using_vz_emulation; then
        args+=(--experimental.virtual-machine.type vz)
        if is_macos arm64; then
            args+=(--experimental.virtual-machine.use-rosetta)
        fi
    fi

    # TODO containerEngine.allowedImages.patterns and WSL.integrations
    # TODO cannot be set from the commandline yet
    image_allow_list="$(bool using_image_allow_list)"
    registry="docker.io"
    if using_ghcr_images; then
        registry="ghcr.io"
    fi
    if is_true "${RD_USE_PROFILE:-}"; then
        if is_windows; then
            # Translate any dots in the distro name into $RD_PROTECTED_DOT (e.g. "Ubuntu-22.04")
            # so that they are not treated as setting separator characters.
            add_profile_bool "WSL.integrations.${WSL_DISTRO_NAME//./$RD_PROTECTED_DOT}" true
        fi
        add_profile_bool containerEngine.allowedImages.enabled "$image_allow_list"
        add_profile_list containerEngine.allowedImages.patterns "$registry"
    else
        wsl_integrations="{}"
        if is_windows; then
            wsl_integrations="{\"$WSL_DISTRO_NAME\":true}"
        fi
        mkdir -p "$PATH_CONFIG"
        cat <<EOF >"$PATH_CONFIG_FILE"
{
  "version": 7,
  "WSL": { "integrations": $wsl_integrations },
  "containerEngine": {
    "allowedImages": {
      "enabled": $image_allow_list,
      "patterns": ["$registry"]
    }
  }
}
EOF
    fi

    if using_npm_run_dev; then
        # translate args back into the internal API format
        local api_args=()
        for arg in "${args[@]}"; do
            api_args+=("$(apify_arg "$arg")")
        done
        if suppressing_modal_dialogs; then
            # Don't apify this option
            api_args+=(--no-modal-dialogs)
        fi

        npm run dev -- "${api_args[@]}" "$@" &
    else
        # Detach `rdctl start` because on Windows the process may not exit until
        # Rancher Desktop itself quits.
        if suppressing_modal_dialogs; then
            args+=(--no-modal-dialogs)
        fi
        RD_TEST=bats rdctl start "${args[@]}" "$@" &
    fi
}

# shellcheck disable=SC2120
start_kubernetes() {
    start_container_engine \
        --kubernetes.enabled \
        --kubernetes.version "$RD_KUBERNETES_PREV_VERSION" \
        "$@"
}

start_application() {
    start_kubernetes
    wait_for_apiserver

    # the docker context "rancher-desktop" may not have been written
    # even though the apiserver is already running
    if using_docker; then
        wait_for_container_engine
    fi
}

get_container_engine_info() {
    run ctrctl info
    echo "$output"
    assert_success || return
    assert_output --partial "Server Version:"
}

docker_context_exists() {
    run docker_exe context ls -q
    assert_success || return
    assert_line "$RD_DOCKER_CONTEXT"
}

assert_service_status() {
    local service_name=$1
    local expect=$2

    run rdsudo rc-service "$service_name" status
    # Some services (e.g. k3s) report non-zero status when not running
    if [[ $expect == started ]]; then
        assert_success || return
    fi
    assert_output --partial "status: ${expect}"
}

wait_for_service_status() {
    local service_name=$1
    local expect=$2

    trace "waiting for ${service_name} to be ${expect}"
    try --max 30 --delay 5 assert_service_status "$service_name" "$expect"
}

rdctl_api_settings() {
    run rdctl api /settings
    echo "$output"
    assert_success || return
    refute_output undefined
}

wait_for_container_engine() {
    local CALLER
    CALLER=$(this_function)

    trace "waiting for api /settings to be callable"
    try --max 30 --delay 5 rdctl_api_settings

    run jq_output .containerEngine.allowedImages.enabled
    assert_success
    if [[ $output == true ]]; then
        wait_for_service_status openresty started
    else
        wait_for_service_status openresty stopped
    fi

    if using_docker; then
        trace "waiting for docker context to exist"
        try --max 30 --delay 5 docker_context_exists
    else
        wait_for_service_status buildkitd started
    fi

    trace "waiting for container engine info to be available"
    try --max 12 --delay 10 get_container_engine_info
}
