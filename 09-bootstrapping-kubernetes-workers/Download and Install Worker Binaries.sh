wget -q --show-progress --https-only --timestamping \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.26.1/crictl-v1.26.1-linux-amd64.tar.gz \
  https://github.com/opencontainers/runc/releases/download/v1.1.6/runc.amd64 \
  https://github.com/containernetworking/plugins/releases/download/v1.2.0/cni-plugins-linux-amd64-v1.2.0.tgz \
  https://github.com/containerd/containerd/releases/download/v1.6.20/containerd-1.6.20-linux-amd64.tar.gz \
  https://storage.googleapis.com/kubernetes-release/release/v1.26.0/bin/linux/amd64/kubectl \
  https://storage.googleapis.com/kubernetes-release/release/v1.26.0/bin/linux/amd64/kube-proxy \
  https://storage.googleapis.com/kubernetes-release/release/v1.26.0/bin/linux/amd64/kubelet

sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

{
  mkdir containerd
  tar -xvf crictl-v1.26.1-linux-amd64.tar.gz
  tar -xvf containerd-1.6.20-linux-amd64.tar.gz -C containerd
  sudo tar -xvf cni-plugins-linux-amd64-v1.2.0.tgz -C /opt/cni/bin/
  sudo mv runc.amd64 runc
  chmod +x crictl kubectl kube-proxy kubelet runc 
  sudo mv crictl kubectl kube-proxy kubelet runc /usr/local/bin/
  sudo mv containerd/bin/* /bin/
}