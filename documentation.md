# 09 - Bootstraping Kubernetes Workers
## Introduction
Dans cette partie, nous allons configurer les workers de notre cluster Kubernetes. Nous allons installer les composants nécessaires pour que les workers puissent communiquer avec le load balancer (ctrl) et les autres workers. Nous allons également installer le CNI (Container Network Interface) qui va nous permettre de définir les règles de routage entre les pods.

## Prérequis
Sur les deux workers, nous devons configurer de nouveaux modules pour supporter les overlay networks, puis activer le routage dans le kernel via sysctl. Nous devons également désactiver apparmor pour éviter des problèmes de compatibilité avec containerd.

```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

 cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
sudo sysctl --system

sudo systemctl stop apparmor
sudo systemctl disable apparmor 
```

### Dépendances
Nous allons installer les dépendances nécessaires pour installer les services des workers.

```bash
sudo apt-get update
sudo apt-get -y install socat conntrack ipset
```
### Désactivation de swap
Nous allons désactiver swap sur les deux workers pour s'assurer que Kubernetes ne l'utilise pas.

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

## Téléchargement et installation des binaires
Nous allons récuperer les binaires pour Kubernetes 1.26 des services et outils suivants : kubelet, kube-proxy, kubectl, containerd, runc et crictl.
```
wget -q --show-progress --https-only --timestamping \
https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.26.1/crictl-v1.26.1-linux-amd64.tar.gz \
https://github.com/opencontainers/runc/releases/download/v1.1.6/runc.amd64 \
https://github.com/containernetworking/plugins/releases/download/v1.2.0/cni-plugins-linux-amd64-v1.2.0.tgz \
https://github.com/containerd/containerd/releases/download/v1.6.20/containerd-1.6.20-linux-amd64.tar.gz \
https://storage.googleapis.com/kubernetes-release/release/v1.26.0/bin/linux/amd64/kubectl \
https://storage.googleapis.com/kubernetes-release/release/v1.26.0/bin/linux/amd64/kube-proxy \
https://storage.googleapis.com/kubernetes-release/release/v1.26.0/bin/linux/amd64/kubelet
```

Nous allons créer les répertoires nécessaires pour installer les binaires.

```bash
sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes
```

Nous allons décompresser les binaires et les installer dans les répertoires correspondants.

```bash
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
```

## Configuration du réseau containerd via le plugin CNI
Nous allons configurer le plugin CNI pour containerd. Nous allons utiliser le plugin bridge qui va créer un bridge réseau sur lequel les pods vont se connecter.

Sur chaque worker, on va définir la variable $POD_CIDR avec le réseau IP du pod network pour le worker.
- kube-work1 = 10.200.0.0/24
- kube-work2 = 10.200.1.0/24

```bash
cat <<EOF | sudo tee /etc/cni/net.d/10-bridge.conf
{
    "cniVersion": "0.4.0",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "${POD_CIDR}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
EOF
```
```bash
cat <<EOF | sudo tee /etc/cni/net.d/99-loopback.conf
{
    "cniVersion": "0.4.0",
    "type": "loopback"
}
EOF
```

> Ici nous utilisons une configuration de version < 1.0.0 alors que la version actuelle est >1.0.0. Pas de panique, ça reste compatible.

## Configuration de containerd

### Création de la configuration
    
```bash
sudo mkdir -p /etc/containerd

cat <<EOF | sudo tee /etc/containerd/config.toml
[plugins]
[plugins.cri.containerd]
    snapshotter = "overlayfs"
    [plugins.cri.containerd.runtimes.runc.options]
    SystemdCgroup = true
    [plugins.cri.containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"
[plugins.cri.cni]
conf_dir = "/etc/cni/net.d"
bin_dir = "/opt/cni/bin"
max_conf_num= 2
EOF
```
> La configuration permet d'activer l'utilisation de systemd cgroup et du plugin CNI pour le réseau.

### Configuration du service containerd
Nous allons configurer le service containerd pour qu'il démarre au boot et qu'il utilise la configuration précédente.

```bash
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
```

## Configuration de kubelet
### Création des certificats et configuration
```bash
{
  sudo mv ${HOSTNAME}-key.pem ${HOSTNAME}.pem /var/lib/kubelet/
  sudo mv ${HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
  sudo mv ca.pem /var/lib/kubernetes/
}
```

Nous allons créer le fichier de configuration de kubelet.

```bash
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
podCIDR: $POD_CIDR 
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/${HOSTNAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${HOSTNAME}-key.pem"
```

> Ne pas oublier que la valeur de pod CIDR varie en fonction du worker !

### Configuration du service kubelet
```bash
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/kubelet-config.yaml \
  --container-runtime=remote \
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \
  #--image-pull-progress-deadline=2m \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  #--network-plugin=cni \
  --register-node=true \
  --cgroup-driver=systemd \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

## Configuration de kube-proxy
```bash
sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
```

On créer le fichier de configuration `kube-proxy-config.yaml` avec le contenu suivant :
```bash
cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
EOF
```

### Configuration du service kube-proxy
```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

## Démarrage des services
```bash
{
  sudo systemctl daemon-reload
  sudo systemctl enable containerd kubelet kube-proxy
  sudo systemctl start containerd kubelet kube-proxy
}
```

## Vérification des workers
Sur notre machine d'administration, nous allons vérifier que les workers sont bien enregistrés dans le cluster.

```bash
kubectl get nodes --kubeconfig admin.kubeconfig
```

```
pierre@kube-ctrl1:~$ kubectl get nodes --kubeconfig admin.kubeconfig
NAME         STATUS   ROLES    AGE   VERSION
kube-work1   Ready    <none>   20h   v1.26.0
kube-work2   Ready    <none>   20h   v1.26.0
```

Ici, nous avons bien nos deux workers.

# 10 - Configuration de kubectl
Nous allons maintenant configurer kubectl pour pouvoir interagir avec notre cluster.

> Cette partie se passe sur votre noeud d'administration.

> N'oubliez pas de définir la valeur de $KUBERNETES_PUBLIC_ADDRESS , qui devrait ici être l'ip de notre load balancer (dans notre cas, 192.168.10.28), afin de taper correctement sur l'API de notre cluster.

## Admin Kubernetes Configuration File
```bash
{
  KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
    --region $(gcloud config get-value compute/region) \
    --format 'value(address)')

  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443

  kubectl config set-credentials admin \
    --client-certificate=admin.pem \
    --client-key=admin-key.pem

  kubectl config set-context kubernetes-the-hard-way \
    --cluster=kubernetes-the-hard-way \
    --user=admin

  kubectl config use-context kubernetes-the-hard-way
}
```

On vérifie que le cluster retourne les bonnes informations
```bash
pierre@kube-ctrl1:~$ kubectl version
WARNING: This version information is deprecated and will be replaced with the output from kubectl version --short.  Use --output=yaml|json to get the full version.
Client Version: version.Info{Major:"1", Minor:"26", GitVersion:"v1.26.3", GitCommit:"9e644106593f3f4aa98f8a84b23db5fa378900bd", GitTreeState:"clean", BuildDate:"2023-03-15T13:40:17Z", GoVersion:"go1.19.7", Compiler:"gc", Platform:"linux/amd64"}
Kustomize Version: v4.5.7
Server Version: version.Info{Major:"1", Minor:"26", GitVersion:"v1.26.3", GitCommit:"9e644106593f3f4aa98f8a84b23db5fa378900bd", GitTreeState:"clean", BuildDate:"2023-03-15T13:33:12Z", GoVersion:"go1.19.7", Compiler:"gc", Platform:"linux/amd64"}

pierre@kube-ctrl1:~$ kubectl get nodes
NAME         STATUS   ROLES    AGE   VERSION
kube-work1   Ready    <none>   20h   v1.26.0
kube-work2   Ready    <none>   20h   v1.26.0
```

# 11 - Provision des routes vers les réseaux des pods
Nous allons maintenant configurer les routes pour que les pods puissent communiquer entre eux sur chaque worker.

Comme nous avons deux workers, nous allons donc devoir configurer seulement la route du réseau de pod du worker2 sur le worker1 et inversement.
> Cela signifie également que chaque worker en plus augmente exponentiellement le nombre de routes à configurer. Il faudra penser à écrire un script pour le faire pour vous !

## Route vers le réseau de pod du worker2 (sur le worker1)
```bash
ip route add 10.200.1.0/24 via 192.168.10.27
```
## Route vers le réseau de pod du worker1 (sur le worker2)
```bash
ip route add 10.200.0.0/24 via 192.168.10.29
```

> Changez le next-hop par l'IP de service du worker de destination, et le réseau vers le quel router par le pod CIDR configuré sur le worker en question

# 12 - Configuration de Core-DNS et test des pods / workers
Nous allons maintenant configurer CoreDNS pour que les pods puissent se résoudre entre eux.

## Application du DNS Addon sur le cluster
```bash
kubectl apply -f https://storage.googleapis.com/kubernetes-the-hard-way/coredns-1.8.yaml
```
```
pierre@kube-ctrl1:~$ kubectl apply -f https://storage.googleapis.com/kubernetes-the-hard-way/coredns-1.8.yaml
serviceaccount/coredns created
clusterrole.rbac.authorization.k8s.io/system:coredns created
clusterrolebinding.rbac.authorization.k8s.io/system:coredns created
configmap/coredns created
Warning: spec.template.spec.nodeSelector[beta.kubernetes.io/os]: deprecated since v1.14; use "kubernetes.io/os" instead
deployment.apps/coredns created
service/kube-dns created
```

On vérifie ensuite que les pods nouvellement crées dans le namespace kube-system sont bien en cours d'exécution
```bash
pierre@kube-ctrl1:~$ kubectl get pods -l k8s-app=kube-dns -n kube-system
NAME                       READY   STATUS             RESTARTS         AGE
coredns-57d48b7dd7-8qlxk   0/1     CrashLoopBackOff   10 (3m34s ago)   29m
coredns-57d48b7dd7-l7htk   0/1     CrashLoopBackOff   10 (3m16s ago)   29m
```

> Ici, nous avons un problème. Les pods ne sont pas en cours d'exécution. Nous allons donc devoir regarder les logs de ces pods pour comprendre pourquoi.

# 13 - Smoke Test
Le but de cette partie est de vérifier que notre cluster est bien fonctionnel.

## Test avec un deployment : nginx
### Application du deployment
On applique un deployment avec l'image docker nginx
```bash
kubectl create deployment nginx --image=nginx
```

On vérifie ensuite le/les pods crées et leur santée
```bash
kubectl get pods -l app=nginx
```
```
NAME                     READY   STATUS    RESTARTS   AGE
nginx-748c667d99-5sxcq   1/1     Running   0          55s
```
Notre deployment semble être en bonne santée

### Configuration du Port Forwarding
On applique les règles de port forwarding pour publiquer le port 8080 du worker sur le port 80 du pod nginx
```bash
POD_NAME=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}")
kubectl port-forward $POD_NAME 8080:80
```