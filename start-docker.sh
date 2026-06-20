#!/bin/bash
set -euo pipefail

source /opt/bash-utils/logger.sh

# Docker-in-Docker on EKS + Kata/Cloud Hypervisor commonly has the container
# root filesystem on virtiofs. Linux overlayfs cannot use virtiofs as Docker's
# upperdir/workdir, so dockerd may start but container creation fails with:
#   failed to mount ... fstype: overlay ... err: invalid argument
#
# To keep overlay2 working, create a sparse loop-backed ext4 filesystem and use
# it as Docker's data-root. This is equivalent to manually running dockerd with:
#   --data-root=/var/lib/docker-ext4 --storage-driver=overlay2

DOCKER_EXT4_IMG="${DOCKER_EXT4_IMG:-/var/lib/docker.ext4.img}"
DOCKER_EXT4_SIZE="${DOCKER_EXT4_SIZE:-20G}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/var/lib/docker-ext4}"
DOCKER_STORAGE_DRIVER="${DOCKER_STORAGE_DRIVER:-overlay2}"
DOCKERD_LOG="${DOCKERD_LOG:-/var/log/dockerd.out.log}"

function wait_for_process () {
    local max_time_wait=30
    local process_name="$1"
    local waited_sec=0
    while ! pgrep "$process_name" >/dev/null && ((waited_sec < max_time_wait)); do
        INFO "Process $process_name is not running yet. Retrying in 1 seconds"
        INFO "Waited $waited_sec seconds of $max_time_wait seconds"
        sleep 1
        ((waited_sec=waited_sec+1))
        if ((waited_sec >= max_time_wait)); then
            return 1
        fi
    done
    return 0
}

function wait_for_docker_api () {
    local max_time_wait=60
    local waited_sec=0

    # dockerd may be running but not yet ready to accept API requests.
    # Wait until the Docker API responds successfully to avoid race conditions
    # with subsequent docker commands.
    while ! docker info >/dev/null 2>&1 && ((waited_sec < max_time_wait)); do
        INFO "Docker API is not ready yet. Retrying in 1 seconds"
        INFO "Waited $waited_sec seconds of $max_time_wait seconds"
        sleep 1
        ((waited_sec=waited_sec+1))
        if ((waited_sec >= max_time_wait)); then
            return 1
        fi
    done
    return 0
}

function ensure_loop_device_nodes () {
    # /dev in containers often lacks loop nodes even when the kernel supports
    # loop devices. Create the standard nodes; ignore failures so environments
    # with pre-created or restricted /dev can still proceed/fail naturally.
    if [ ! -e /dev/loop-control ]; then
        mknod /dev/loop-control c 10 237 || true
    fi

    for i in $(seq 0 15); do
        [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" || true
    done
}

function configure_docker_daemon () {
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "storage-driver": "${DOCKER_STORAGE_DRIVER}"
}
EOF
}

function mount_docker_ext4_data_root () {
    mkdir -p "${DOCKER_DATA_ROOT}" /var/run
    ensure_loop_device_nodes

    if [ ! -f "${DOCKER_EXT4_IMG}" ]; then
        INFO "Creating sparse Docker backing image ${DOCKER_EXT4_IMG} (${DOCKER_EXT4_SIZE})"
        truncate -s "${DOCKER_EXT4_SIZE}" "${DOCKER_EXT4_IMG}"
        mkfs.ext4 -F -q "${DOCKER_EXT4_IMG}"
    fi

    if mountpoint -q "${DOCKER_DATA_ROOT}"; then
        INFO "Docker data-root is already mounted at ${DOCKER_DATA_ROOT}"
        return 0
    fi

    local loopdev
    loopdev="$(losetup -j "${DOCKER_EXT4_IMG}" | awk -F: 'NR==1 {print $1}')"
    if [ -z "${loopdev}" ]; then
        loopdev="$(losetup -f --show "${DOCKER_EXT4_IMG}")"
    fi

    INFO "Mounting ${loopdev} at ${DOCKER_DATA_ROOT}"
    mount "${loopdev}" "${DOCKER_DATA_ROOT}"
}

configure_docker_daemon
mount_docker_ext4_data_root

if docker info >/dev/null 2>&1; then
    INFO "Docker is already running: $(docker info --format 'driver={{.Driver}} root={{.DockerRootDir}}')"
    exit 0
fi

rm -f /var/run/docker.pid

INFO "Starting supervisor"
/usr/bin/supervisord -n >> /dev/null 2>&1 &

INFO "Waiting for docker to be running"
if ! wait_for_process dockerd; then
    ERROR "dockerd is not running after max time"
    tail -100 "${DOCKERD_LOG}" || true
    exit 1
else
    INFO "dockerd is running"
fi

INFO "Waiting for Docker API to become ready"
if ! wait_for_docker_api; then
    ERROR "Docker API did not become ready after max time"
    tail -100 "${DOCKERD_LOG}" || true
    exit 1
else
    INFO "Docker API is ready: $(docker info --format 'driver={{.Driver}} root={{.DockerRootDir}}')"
fi
