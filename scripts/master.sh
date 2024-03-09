#!/bin/bash
#set -u
#set -x

SCRIPTDIR=$(dirname "$0")
WORKINGDIR='/local/repository'
username=$(id -nu)
HOME=/users/$(id -un)
usergid=$(id -ng)
experimentid=$(hostname|cut -d '.' -f 2)
projectid=$usergid

sudo chown ${username}:${usergid} ${WORKINGDIR}/ -R
cd $WORKINGDIR
# Redirect output to log file
exec >> ${WORKINGDIR}/deploy.log
exec 2>&1

KUBEHOME="${WORKINGDIR}/kube"
mkdir -p $KUBEHOME
export KUBECONFIG=$KUBEHOME/admin.conf

# make SSH shells play nice
sudo chsh -s /bin/bash $username
echo "export KUBECONFIG=${KUBECONFIG}" > $HOME/.profile

# add repositories
# Kubernetes
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.25/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.25/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
# Docker
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update apt lists
sudo apt-get update

# Install pre-reqs
sudo apt-get -y install build-essential libffi-dev python python-dev  \
python-pip automake autoconf libtool indent vim tmux ctags xgrep

echo "containerd is installed below --------------------------------------------------------------------------------------------------"
# docker

wget https://github.com/containerd/containerd/releases/download/v1.6.8/containerd-1.6.8-linux-amd64.tar.gz
tar Cxzvf /usr/local containerd-1.6.8-linux-amd64.tar.gz
wget https://github.com/opencontainers/runc/releases/download/v1.1.3/runc.amd64

sudo systemctl daemon-reload
sudo systemctl enable --now containerd

sudo install -m 755 runc.amd64 /usr/local/sbin/runc
wget https://github.com/containernetworking/plugins/releases/download/v1.1.1/cni-plugins-linux-amd64-v1.1.1.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.1.1.tgz

echo " install for containerd finished, -      ------------------------------------------------------------------------------------------------------"
# learn from this: https://blog.csdn.net/yan234280533/article/details/75136630
# more info should see: https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
#sudo apt-get update
sudo apt-get -y install kubelet=1.25.5-1.1 kubeadm=1.25.5-1.1 kubectl=1.25.5-1.1 kubernetes-cni golang-go jq



# Solving issues with cgroup-drivers
#echo '{"exec-opts": ["native.cgroupdriver=systemd"]}' | sudo tee /etc/docker/daemon.json
#sudo systemctl restart docker

sudo swapoff -a
sudo kubeadm config migrate --old-config /local/repository/config/kubeadm-config.yaml --new-config /local/repository/config/kubeadm-config.yaml
sudo kubeadm init --config=config/kubeadm-config.yaml

echo "The kubeadm is initalised, if it gets here without an error above then that means that the problem is further down"

# result will be like:  kubeadm join 155.98.36.111:6443 --token i0peso.pzk3vriw1iz06ruj --discovery-token-ca-cert-hash sha256:19c5fdee6189106f9cb5b622872fe4ac378f275a9d2d2b6de936848215847b98

# allow sN to log in with shared key
# see http://docs.powderwireless.net/advanced-topics.html
geni-get key > ${HOME}/.ssh/id_rsa
chmod 600 ${HOME}/.ssh/id_rsa
ssh-keygen -y -f ${HOME}/.ssh/id_rsa > ${HOME}/.ssh/id_rsa.pub
grep -q -f ${HOME}/.ssh/id_rsa.pub ${HOME}/.ssh/authorized_keys || cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys

# https://github.com/kubernetes/kubernetes/issues/44665
sudo cp /etc/kubernetes/admin.conf $KUBEHOME/
sudo chown ${username}:${usergid} $KUBEHOME/admin.conf

# Install Flannel. See https://github.com/coreos/flannel
sudo kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
sudo kubectl get daemonset -n kube-flannel kube-flannel-ds -o json | jq '.spec.template.spec.containers[0].args += ["--iface-regex=192\\.168\\..*\\..*"]' | sudo kubectl replace -f -

# use this to enable autocomplete
source <(kubectl completion bash)

# Install dashboard: https://github.com/kubernetes/dashboard
# v3 of kubernetes-dashboard has many software dependencies like Nginx Ingress and the set up process
# changes drastically. v2 serves the exact same functionality with a slightly more straightforward setup,
# so we will use the latest v2 (2.7.0) recommended YAML file as a base.
# It has been modified to allow HTTP access and to allow admin login without credentials. More details in
# the file itself.
echo "Launching Kubernetes Dashboard..."
sudo kubectl apply -f config/test/kubernetes-dashboard.yaml

# We should now port-forward the dashboard service which is at port 80 locally,
# but we'll do that later since it'll take a few seconds to get everything ready
# after applying the YAML file, and it's better to do other things (like doing
# other installations) in parallel.
#
# Alternatively we could also run
# sudo kubectl proxy -p 12345 --address='0.0.0.0' --accept-hosts='^*$' &
# here and now, which will make the kubernetes API service public (which can be
# done before dashboard is ready). This is a bit more straightforward than
# port-forwarding in terms of modifying the YAML file, but it makes URLs messy
# since you have to prefix everything with long boilerplate.

# jid for json parsing.
export GOPATH=${WORKINGDIR}/go/gopath
mkdir -p $GOPATH
export PATH=$PATH:$GOPATH/bin
sudo go get -u github.com/simeji/jid/cmd/jid
sudo go build -o /usr/bin/jid github.com/simeji/jid/cmd/jid

# install static cni plugin
sudo go get -u github.com/containernetworking/plugins/plugins/ipam/static
sudo go build -o /opt/cni/bin/static github.com/containernetworking/plugins/plugins/ipam/static

# install helm
echo "Installing Helm"
wget https://get.helm.sh/helm-v3.1.0-linux-amd64.tar.gz
tar xf helm-v3.1.0-linux-amd64.tar.gz
sudo cp linux-amd64/helm /usr/local/bin/helm

source <(helm completion bash)

# run port-forward to make the dashboard portal accessible from outside
echo "Port-forwarding port 80 of dashboard service at public port 12345..."
# Make sure the dashboard pod is ready before port-forwarding, since otherwise
# kubectl port-forward will fail. This adds a slight delay to the setup but it
# should be very negligible because we've moved the waiting/port-forwarding to
# after the helm installation above, which should give it enough time to start
# up in the background. 
kubectl wait -n kubernetes-dashboard --for=condition=ready pod --all
sudo kubectl port-forward services/kubernetes-dashboard -n kubernetes-dashboard --address='0.0.0.0' 12345:80 &

# Wait till the slave nodes get joined and update the kubelet daemon successfully
# number of slaves + 1 master
node_cnt=$(($(/local/repository/scripts/geni-get-param computeNodeCount) + 1))
# 1 node per line - header line
joined_cnt=$(( `kubectl get nodes | wc -l` - 1 ))
echo "Total nodes: $node_cnt Joined: ${joined_cnt}"
while [ $node_cnt -ne $joined_cnt ]
do 
    joined_cnt=$(( `kubectl get nodes |wc -l` - 1 ))
    sleep 1
done
echo "All nodes joined"

# Display for the end-user where the Kubernetes dashboard is, using our public
# hostname
echo "Kubernetes is ready at: http://$(hostname --fqdn):12345"

# Also make the link display on every SSH login too, for convenience:
BOLD_RESET="\033[22m"
BOLD="\033[1m"
GREEN="\033[32m"
BLUE="\033[34m"
RED="\033[31m"
RESET="\033[0m"

cat <<ASD >> /users/${username}/.ssh/rc
test -z \$SSH_TTY && return # Don't run when not-interactive like SCP
echo "${GREEN}==================${RESET}"
echo "${GREEN}This is the ${BOLD}Nervion${BOLD_RESET} Kubernetes cluster ${BOLD}master node${BOLD_RESET}."
echo "${BOLD}Nervion Kubernetes Dashboard:${RESET} http://$(hostname --fqdn):12345"
echo ""
echo "${BLUE}When prompted for authentication, press \"Skip\" to use the built-in admin account."
echo "${RED}${BOLD}Warning: ${BOLD_RESET}This deployment is for research purposes only. Having a publicly accessible admin Kubernetes dashboard like this is dangerous for anything else.${RESET}"
echo ""
echo "${GREEN}${BOLD}Nervion Controller UI:${RESET} http://$(hostname --fqdn):34567"
echo "${GREEN}==================${RESET}"
ASD

#Deploy metrics server
sudo kubectl create -f config/test/metrics-server.yaml
# Deploy emulator
sudo kubectl create -f config/deployment.yaml

# Log all the traffic on the Nervion master node
#sudo tcpdump -i any -w ~/tcpdump.pcap &

# to know how much time it takes to instantiate everything.
echo "Setup DONE!"
date
