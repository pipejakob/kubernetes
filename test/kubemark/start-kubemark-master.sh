#!/bin/bash

# Copyright 2015 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# TODO: figure out how to get etcd tag from some real configuration and put it here.

EVENT_STORE_IP=$1
EVENT_STORE_URL="http://${EVENT_STORE_IP}:4002"
NUM_NODES=$2
TEST_ETCD_VERSION=$3
if [[ -z "${TEST_ETCD_VERSION}" ]]; then
  # Default etcd version.
  TEST_ETCD_VERSION="2.2.1"
fi

function retry() {
	for i in {1..4}; do
		"$@" && return 0 || sleep $i
	done
	"$@"
}

function mount-master-pd() {
	if [[ ! -e /dev/disk/by-id/google-master-pd ]]; then
		echo "Can't find master-pd. Skipping mount."
		return
	fi
	device_info=$(ls -l "/dev/disk/by-id/google-master-pd")
	relative_path=${device_info##* }
	pd_device="/dev/disk/by-id/${relative_path}"

	echo "Mounting master-pd"
	local -r pd_path="/dev/disk/by-id/google-master-pd"
	local -r mount_point="/mnt/disks/master-pd"
	# Format and mount the disk, create directories on it for all of the master's
	# persistent data, and link them to where they're used.
	mkdir -p "${mount_point}"

	device=$1
	mountpoint=$2

	# Format only if the disk is not already formatted.
	if ! tune2fs -l "${pd_path}" ; then
		echo "Formatting '${pd_path}'"
		mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "${pd_path}"
	fi

	mkdir -p "${mount_point}"
	echo "Mounting '${pd_path}' at '${mount_point}'"
	mount -o discard,defaults "${pd_path}" "${mount_point}"
	echo "Mounted master-pd '${pd_path}' at '${mount_point}'"

	# Contains all the data stored in etcd.
	mkdir -m 700 -p "${mount_point}/var/etcd"
	ln -s -f "${mount_point}/var/etcd" /var/etcd
	mkdir -p /etc/srv
	# Contains the dynamically generated apiserver auth certs and keys.
	mkdir -p "${mount_point}/srv/kubernetes"
	ln -s -f "${mount_point}/srv/kubernetes" /etc/srv/kubernetes
	# Directory for kube-apiserver to store SSH key (if necessary).
	mkdir -p "${mount_point}/srv/sshproxy"
	ln -s -f "${mount_point}/srv/sshproxy" /etc/srv/sshproxy

	if ! id etcd &>/dev/null; then
		useradd -s /sbin/nologin -d /var/etcd etcd
	fi
}

if [ "${EVENT_STORE_IP}" == "127.0.0.1" ]; then
	# Retry starting etcd to avoid pulling image errors.
	retry sudo docker run --net=host \
		-v /var/etcd/data-events:/var/etcd/data -v /var/log:/var/log -d \
		gcr.io/google_containers/etcd:${TEST_ETCD_VERSION} /bin/sh -c "/usr/local/bin/etcd \
		--listen-peer-urls http://127.0.0.1:2381 \
		--advertise-client-urls=http://127.0.0.1:4002 \
		--listen-client-urls=http://0.0.0.0:4002 \
		--data-dir=/var/etcd/data 1>> /var/log/etcd-events.log 2>&1"
fi

# Retry starting etcd to avoid pulling image errors.
retry sudo docker run --net=host \
	-v /var/etcd/data:/var/etcd/data -v /var/log:/var/log -d \
	gcr.io/google_containers/etcd:${TEST_ETCD_VERSION} /bin/sh -c "/usr/local/bin/etcd \
	--listen-peer-urls http://127.0.0.1:2380 \
	--advertise-client-urls=http://127.0.0.1:2379 \
	--listen-client-urls=http://0.0.0.0:2379 \
	--data-dir=/var/etcd/data 1>> /var/log/etcd.log 2>&1"

# Increase the allowed number of open file descriptors
ulimit -n 65536

mount-master-pd

tar xzf kubernetes-server-linux-amd64.tar.gz

kubernetes/server/bin/kube-scheduler --master=127.0.0.1:8080 $(cat scheduler_flags) &> /var/log/kube-scheduler.log &

kubernetes/server/bin/kube-apiserver \
	--insecure-bind-address=0.0.0.0 \
	--etcd-servers=http://127.0.0.1:2379 \
	--etcd-servers-overrides=/events#${EVENT_STORE_URL} \
	--tls-cert-file=/srv/kubernetes/server.cert \
	--tls-private-key-file=/srv/kubernetes/server.key \
	--client-ca-file=/srv/kubernetes/ca.crt \
	--token-auth-file=/srv/kubernetes/known_tokens.csv \
	--secure-port=443 \
	--basic-auth-file=/srv/kubernetes/basic_auth.csv \
	--target-ram-mb=$((${NUM_NODES} * 60)) \
	$(cat apiserver_flags) &> /var/log/kube-apiserver.log &

# kube-contoller-manager now needs running kube-api server to actually start
until [ "$(curl 127.0.0.1:8080/healthz 2> /dev/null)" == "ok" ]; do
	sleep 1
done
kubernetes/server/bin/kube-controller-manager \
  --master=127.0.0.1:8080 \
  --service-account-private-key-file=/srv/kubernetes/server.key \
  --root-ca-file=/srv/kubernetes/ca.crt \
  $(cat controllers_flags) &> /var/log/kube-controller-manager.log &
