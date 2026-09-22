#!/bin/bash

CGROUP_FS="/sys/fs/cgroup"
if [ ! -e "$CGROUP_FS" ]; then
  echo "Cannot find $CGROUP_FS. Please make sure your system is using cgroup v2"
  exit 1
fi

if [ -e "$CGROUP_FS/unified" ]; then
  echo "Combined cgroup v1+v2 mode is not supported. Please make sure your system is using pure cgroup v2"
  exit 1
fi

if [ ! -e "$CGROUP_FS/cgroup.subtree_control" ]; then
  echo "Cgroup v2 not found. Please make sure cgroup v2 is enabled on your system"
  exit 1
fi

# Each replica uses its own cgroup subtree named after the container hostname
# (api1, api2, api3) so box IDs never collide between replicas on the same host.
# isolate's cg_root is hardcoded in /usr/local/etc/isolate — patch it at startup.
ISOLATE_DIR="isolate-${HOSTNAME:-default}"
sed -i "s|cg_root = /sys/fs/cgroup/isolate$|cg_root = /sys/fs/cgroup/${ISOLATE_DIR}|" \
    /usr/local/etc/isolate

cd /sys/fs/cgroup && \
mkdir -p "${ISOLATE_DIR}/" && \
echo $$ > "${ISOLATE_DIR}/cgroup.procs" && \
echo '+cpuset +cpu +io +memory +pids' > cgroup.subtree_control && \
cd "${ISOLATE_DIR}" && \
mkdir -p init && \
echo $$ > init/cgroup.procs && \
echo '+cpuset +memory' > cgroup.subtree_control && \
echo "Initialized cgroup at /sys/fs/cgroup/${ISOLATE_DIR}" && \
chown -R piston:piston /piston && \
exec su -- piston -c 'ulimit -n 65536 2>/dev/null || true; exec node /piston_api/src'
