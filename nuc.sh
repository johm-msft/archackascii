#### Start nuc-vm-install.sh script ######
##########################################

#### Configure Linux
echo "### START Update Linux ###"
# Install SSH if not already there
sudo apt-get install -y openssh-server
sudo systemctl enable ssh

# Install all updates
sudo apt update && sudo apt upgrade -y

# Disable swap (needed for k8s)
sudo sed -i '/\/swap.img/d' /etc/fstab
sudo swapoff -a
echo "### START Update Linux ###"

### Stage 0 of standard Install script
# Needs to be run as root
# sudo su -
if [ $EUID -ne 0 ]; then
  echo "MUST BE RUN AS ROOT"
exit 1
fi

#### Install Docker and Kubeadm 
echo "### START Install Docker ###"
# Install docker.  From https://kubernetes.io/docs/setup/cri/.  Get necessary packages first. 
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update && sudo apt-get install -y docker-ce=18.06.0~ce~3-0~ubuntu
cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo systemctl daemon-reload
sudo systemctl restart docker
echo "### END Install Docker ###"

echo "### START Install Kubernetes ###"
# Install kubeadm and kubectl. From https://kubernetes.io/docs/setup/independent/install-kubeadm/
# To instead install specific version (not latest stable), see versions with this:
# curl -s https://packages.cloud.google.com/apt/dists/kubernetes-xenial/main/binary-amd64/Packages | grep Version | awk '{print $2}'
# or with: apt policy kubeadm
# And specify version on apt-get install command, eg this:
# sudo apt-get install -y kubelet=1.16.7-00 kubeadm=1.16.7-00 kubectl=1.16.7-00
sudo apt-get update && sudo apt-get install -y apt-transport-https curl
sudo curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
    
# Allow net.ipv4.tcp_syn_retries to be configured
# Slightly unclear what the reason for this is
if grep -q tcp_syn_retries /etc/default/kubelet; then
  echo "tcp_syn_retries already configured"
else
  if grep -q KUBELET_CONFIG /etc/default/kubelet; then
    grep -- '--allowed-unsafe-sysctls net.ipv4.tcp_syn_retries' /etc/default/kubelet || (sed -E 's/^(KUBELET_CONFIG=.*)/\1 --allowed-unsafe-sysctls net.ipv4.tcp_syn_retries/' -i /etc/default/kubelet)
  else
    echo 'KUBELET_CONFIG=--allowed-unsafe-sysctls net.ipv4.tcp_syn_retries' >> /etc/default/kubelet
  fi
  sudo systemctl daemon-reload
  sudo service kubelet restart
  sudo sleep 30
fi
echo "### END Install Kubernetes ###"

echo "### START Linux Tweaks ###"
# Bridge Utils (useful for diags, not fundamental)
sudo apt install bridge-utils

# Collect kernel core files (useful for diags) - Fusion Core helm charts will rely on these directories for logs/core files existing on nodes
sudo echo kernel.core_pattern = /home/ubuntu/corefiles/core.%e.%p.%t.%s > /etc/sysctl.d/60-ngc-core-pattern.conf
sysctl -p /etc/sysctl.d/60-ngc-core-pattern.conf
sudo mkdir /var/log/metaswitch-cores

#### Stage 1
# Enable hugepages - necessary for UPF
GRUB_CONFIG="/etc/default/grub"
sed -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 crashkernel=auto console=ttyS0,115200 default_hugepagesz=1G hugepagesz=1G hugepages=2"/g' -i $GRUB_CONFIG
grub-mkconfig -o /boot/grub/grub.cfg
echo "### END Linux Tweaks ###"

echo "### START Kubeadm initiatlize Kubernetes ###"
#### Stage 2
### Install and initialize Kubernetes
# Basic install via kubeadm. From https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
kubeadm init --pod-network-cidr=10.244.0.0/16 --control-plane-endpoint=$HOSTNAME
sleep 30
echo "### END Kubeadm initiatlize Kubernetes ###"

# Ceate credentials
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Allow scheduling on master node
kubectl taint node $HOSTNAME node-role.kubernetes.io/master:NoSchedule-

# Install k8s dashboard (based on https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta8/aio/deploy/recommended.yaml

echo "### START Install CNI Plugins ###"
# Install CNI plugins (this takes latest version of each)
kubectl apply -f https://raw.githubusercontent.com/intel/multus-cni/master/images/multus-daemonset.yml
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# Install latest CNI plugin binaries (need static, not thereby default, and need latest vesion of host-device to suppot IPAM and device renaming)
mkdir tmp
cd tmp
wget https://github.com/containernetworking/plugins/releases/download/v0.8.5/cni-plugins-linux-amd64-v0.8.5.tgz
tar -xvzf cni-plugins-linux-amd64-v0.8.5.tgz
sudo mkdir /opt/cni/bin/old
sudo cp /opt/cni/bin/* /opt/cni/bin/old/
sudo cp * /opt/cni/bin/
cd ..
rm -rf tmp
echo "### END Install CNI Plugins ###"

echo "### START Install Helm ###"
# Install Helm (this takes latest v3)
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Tweak k8s dashboard access (optional)
# kubectl -n kube-system edit service kubernetes-dashboard
# Find type: ClusterIP, replace with type: NodePort and sav
# kubectl -n kube-system edit deployment kubernetes-dashboard
# Find the args: section for the container. Add a new line ‘- --token-ttl=43200’ below the existing line ‘- --auto-generate-certificates’ and save.
echo "### END Install Helm ###"

# END ROOT 

#### End nuc-vm-install.sh script ######
