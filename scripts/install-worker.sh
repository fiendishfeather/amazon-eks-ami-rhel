#!/usr/bin/env bash

#The sample code; software libraries; command line tools; proofs of concept; templates; or other related technology (including any of the foregoing that are provided by our personnel)
#is provided to you as AWS Content under the AWS Customer Agreement, or the relevant written agreement between you and AWS (whichever applies).
#You should not use this AWS Content in your production accounts, or on production or other critical data. You are responsible for testing, securing, and optimizing the AWS Content,
#such as sample code, as appropriate for production grade use based on your specific quality control practices and standards.
#Deploying AWS Content may incur AWS charges for creating or using AWS chargeable resources, such as running Amazon EC2 instances or using Amazon S3 storage.

set -o pipefail
set -o nounset
set -o errexit
IFS=$'\n\t'
export AWS_DEFAULT_OUTPUT="json"

################################################################################
### Validate Required Arguments ################################################
################################################################################
validate_env_set() {
  (
    set +o nounset

    if [ -z "${!1}" ]; then
      echo "Packer variable '$1' was not set. Aborting"
      exit 1
    fi
  )
}

validate_env_set BINARY_BUCKET_NAME
validate_env_set BINARY_BUCKET_REGION
validate_env_set S3_INSTANCE_ROLE
validate_env_set DOCKER_VERSION
validate_env_set CONTAINERD_VERSION
validate_env_set RUNC_VERSION
validate_env_set CNI_PLUGIN_VERSION
validate_env_set KUBERNETES_VERSION
validate_env_set KUBERNETES_BUILD_DATE
validate_env_set PULL_CNI_FROM_GITHUB
validate_env_set PAUSE_CONTAINER_VERSION
validate_env_set CACHE_CONTAINER_IMAGES
validate_env_set WORKING_DIR
validate_env_set INSTALL_SSM_AGENT
validate_env_set SSM_AGENT_VERSION
validate_env_set INSTALL_AWSCLI
validate_env_set INSTALL_CLOUDFORMATION_HELPER

################################################################################
### Machine Architecture #######################################################
################################################################################

MACHINE=$(uname -m)
if [ "$MACHINE" == "x86_64" ]; then
  ARCH="amd64"
elif [ "$MACHINE" == "aarch64" ]; then
  ARCH="arm64"
else
  echo "Unknown machine architecture '$MACHINE'" >&2
  exit 1
fi

################################################################################
### Packages ###################################################################
################################################################################

# Update the OS to begin with to catch up to the latest packages.
sudo yum update -y

# Install necessary packages
sudo yum install -y \
  chrony \
  conntrack \
  curl \
  iptables \
  ipvsadm \
  jq \
  nfs-utils \
  python3 \
  socat \
  unzip \
  wget \
  yum-utils \
  yum-plugin-versionlock

# Install Cloudformation helper
if [ "$INSTALL_CLOUDFORMATION_HELPER" = "true" ]; then
  echo "Installing CloudFormation Helper"
  sudo mkdir -p /opt/aws/bin
  #cd /opt/aws/bin
  sudo wget https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz -q
  #sudo python3 -m easy_install --script-dir /opt/aws/bin aws-cfn-bootstrap-py3-latest.tar.gz
  tar xvf aws-cfn-bootstrap-py3-latest.tar.gz
  cd aws-cfn-bootstrap-2.0
  sudo python3 setup.py build
  sudo python3 setup.py install --install-scripts /opt/aws/bin
fi

# Remove any old kernel versions. `--count=1` here means "only leave 1 kernel version installed"
sudo dnf remove --oldinstallonly --setopt installonly_limit=2 -y || true
sudo yum versionlock kernel-$(uname -r)

# Remove the ec2-net-utils package, if it's installed. This package interferes with the route setup on the instance.
if yum list installed | grep ec2-net-utils; then sudo yum remove ec2-net-utils -y -q; fi

sudo mkdir -p /etc/eks/

################################################################################
### Time #######################################################################
################################################################################

sudo mv $WORKING_DIR/configure-clocksource.service /etc/eks/configure-clocksource.service

################################################################################
### SSH ########################################################################
################################################################################

# Disable weak ciphers
echo -e "\nCiphers aes128-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart sshd.service

################################################################################
### iptables ###################################################################
################################################################################

sudo mv $WORKING_DIR/iptables-restore.service /etc/eks/iptables-restore.service

################################################################################
### awscli #####################################################################
################################################################################

### CLI gets ignored since we install it with ImageManager
### isolated regions can't communicate to awscli.amazonaws.com so installing awscli through yum
if [ "$INSTALL_AWSCLI" = "true" ]; then
  ISOLATED_REGIONS=(us-iso-east-1 us-iso-west-1 us-isob-east-1)
  if ! [[ " ${ISOLATED_REGIONS[*]} " =~ " ${BINARY_BUCKET_REGION} " ]]; then
    # https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
    echo "Installing awscli v2 bundle"
    AWSCLI_DIR="${WORKING_DIR}/awscli-install"
    mkdir "${AWSCLI_DIR}"
    curl \
      --silent \
      --show-error \
      --retry 10 \
      --retry-delay 1 \
      -L "https://awscli.amazonaws.com/awscli-exe-linux-${MACHINE}.zip" -o "${AWSCLI_DIR}/awscliv2.zip"
    unzip -q "${AWSCLI_DIR}/awscliv2.zip" -d ${AWSCLI_DIR}
    sudo "${AWSCLI_DIR}/aws/install" --bin-dir /bin/ --update
  fi
fi

################################################################################
### systemd ####################################################################
################################################################################

sudo mv "${WORKING_DIR}/runtime.slice" /etc/systemd/system/runtime.slice
sudo restorecon /etc/systemd/system/runtime.slice

###############################################################################
### Containerd setup ##########################################################
###############################################################################

# install runc and lock version - runc is not needed with containerd installation.
#sudo yum install -y runc-${RUNC_VERSION}
#sudo yum versionlock runc-*

# install containerd and lock version
sudo wget https://download.docker.com/linux/centos/docker-ce.repo -P /etc/yum.repos.d/ -q
sudo yum install -y containerd.io
sudo yum versionlock containerd*

sudo mkdir -p /etc/eks/containerd
if [ -f "/etc/eks/containerd/containerd-config.toml" ]; then
  ## this means we are building a gpu ami and have already placed a containerd configuration file in /etc/eks
  echo "containerd config is already present"
else
  sudo mv $WORKING_DIR/containerd-config.toml /etc/eks/containerd/containerd-config.toml
fi

sudo mv $WORKING_DIR/kubelet-containerd.service /etc/eks/containerd/kubelet-containerd.service
sudo mv $WORKING_DIR/sandbox-image.service /etc/eks/containerd/sandbox-image.service
sudo mv $WORKING_DIR/pull-sandbox-image.sh /etc/eks/containerd/pull-sandbox-image.sh
sudo mv $WORKING_DIR/pull-image.sh /etc/eks/containerd/pull-image.sh
sudo chmod +x /etc/eks/containerd/pull-sandbox-image.sh
sudo chmod +x /etc/eks/containerd/pull-image.sh

sudo mkdir -p /etc/systemd/system/containerd.service.d
cat << EOF | sudo tee /etc/systemd/system/containerd.service.d/10-compat-symlink.conf
[Service]
ExecStartPre=/bin/ln -sf /run/containerd/containerd.sock /run/dockershim.sock
EOF

cat << EOF | sudo tee -a /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

cat << EOF | sudo tee -a /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

################################################################################
### Docker #####################################################################
################################################################################

sudo yum install -y device-mapper-persistent-data lvm2

if [[ ! -v "INSTALL_DOCKER" ]]; then
  INSTALL_DOCKER=$(vercmp "$KUBERNETES_VERSION" lt "1.25.0" || true)
else
  echo "WARNING: using override INSTALL_DOCKER=${INSTALL_DOCKER}. This option is deprecated and will be removed in a future release."
fi

if [[ "$INSTALL_DOCKER" == "true" ]]; then
  echo "Installing Docker"
  sudo groupadd -og 1950 docker
  sudo useradd --gid $(getent group docker | cut -d: -f3) docker

  # install docker and lock version
  sudo yum install -y docker-${DOCKER_VERSION}*
  sudo yum versionlock docker-*
  sudo usermod -aG docker $USER

  # Remove all options from sysconfig docker.
  sudo sed -i '/OPTIONS/d' /etc/sysconfig/docker || true

  sudo mkdir -p /etc/docker
  sudo mv $WORKING_DIR/docker-daemon.json /etc/docker/daemon.json
  sudo chown root:root /etc/docker/daemon.json

  # Enable docker daemon to start on boot.
  sudo systemctl daemon-reload
fi

################################################################################
### Logrotate ##################################################################
################################################################################

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $WORKING_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy
sudo mv $WORKING_DIR/logrotate.conf /etc/logrotate.conf
sudo chown root:root /etc/logrotate.d/kube-proxy
sudo chown root:root /etc/logrotate.conf
sudo mkdir -p /var/log/journal

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin

echo "Downloading binaries from: s3://$BINARY_BUCKET_NAME"
S3_DOMAIN="amazonaws.com"
if [ "$BINARY_BUCKET_REGION" = "cn-north-1" ] || [ "$BINARY_BUCKET_REGION" = "cn-northwest-1" ]; then
  S3_DOMAIN="amazonaws.com.cn"
elif [ "$BINARY_BUCKET_REGION" = "us-iso-east-1" ] || [ "$BINARY_BUCKET_REGION" = "us-iso-west-1" ]; then
  S3_DOMAIN="c2s.ic.gov"
elif [ "$BINARY_BUCKET_REGION" = "us-isob-east-1" ]; then
  S3_DOMAIN="sc2s.sgov.gov"
fi
S3_URL_BASE="https://$BINARY_BUCKET_NAME.s3.$BINARY_BUCKET_REGION.$S3_DOMAIN/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"
S3_PATH="s3://$BINARY_BUCKET_NAME/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"

BINARIES=(
  kubelet
  aws-iam-authenticator
)

for binary in ${BINARIES[*]}; do
  if [ -n "$AWS_ACCESS_KEY_ID" ] || [ $BINARY_BUCKET_NAME != "amazon-eks" ] || [ $S3_INSTANCE_ROLE = "true" ]; then
    echo "AWS cli present - using it to copy binaries from s3."
    aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary .
    aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary.sha256 .
  else
    echo "AWS cli missing - using wget to fetch binaries from s3. Note: This won't work for private bucket."
    sudo wget $S3_URL_BASE/$binary
    sudo wget $S3_URL_BASE/$binary.sha256
  fi
  sudo sha256sum -c $binary.sha256
  sudo chmod +x $binary
  sudo mv $binary /usr/bin/
done

# Verify that the aws-iam-authenticator is at last v0.5.9 or greater. Otherwise, nodes will be
# unable to join clusters due to upgrading to client.authentication.k8s.io/v1beta1
iam_auth_version=$(sudo /usr/bin/aws-iam-authenticator version | jq -r .Version)
if vercmp "$iam_auth_version" lt "v0.5.9"; then
  # To resolve this issue, you need to update the aws-iam-authenticator binary. Using binaries distributed by EKS
  # with kubernetes_build_date 2022-10-31 or later include v0.5.10 or greater.
  echo "❌ The aws-iam-authenticator should be on version v0.5.9 or later. Found $iam_auth_version"
  exit 1
fi

# Since CNI 0.7.0, all releases are done in the plugins repo.
CNI_PLUGIN_FILENAME="cni-plugins-linux-${ARCH}-${CNI_PLUGIN_VERSION}"

if [ "$PULL_CNI_FROM_GITHUB" = "true" ]; then
  echo "Downloading CNI plugins from Github"
  sudo wget "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/${CNI_PLUGIN_FILENAME}.tgz" -q
  sudo wget "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/${CNI_PLUGIN_FILENAME}.tgz.sha512" -q
  sudo sha512sum -c "${CNI_PLUGIN_FILENAME}.tgz.sha512"
  sudo rm "${CNI_PLUGIN_FILENAME}.tgz.sha512"
else
  if [ -n "$AWS_ACCESS_KEY_ID" ] || [ $BINARY_BUCKET_NAME != "amazon-eks" ] || [ $S3_INSTANCE_ROLE = "true" ]; then
    echo "AWS cli present - using it to copy binaries from s3."
    aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/${CNI_PLUGIN_FILENAME}.tgz .
    aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/${CNI_PLUGIN_FILENAME}.tgz.sha256 .
  else
    echo "AWS cli missing - using wget to fetch cni binaries from s3. Note: This won't work for private bucket."
    sudo wget "$S3_URL_BASE/${CNI_PLUGIN_FILENAME}.tgz"
    sudo wget "$S3_URL_BASE/${CNI_PLUGIN_FILENAME}.tgz.sha256"
  fi
  sudo sha256sum -c "${CNI_PLUGIN_FILENAME}.tgz.sha256"
fi
sudo tar -xvf "${CNI_PLUGIN_FILENAME}.tgz" -C /opt/cni/bin
sudo rm "${CNI_PLUGIN_FILENAME}.tgz"

sudo rm ./*.sha256

sudo mkdir -p /etc/kubernetes/kubelet
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo mv $WORKING_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo chown root:root /var/lib/kubelet/kubeconfig

# Inject CSIServiceAccountToken feature gate to kubelet config if kubernetes version starts with 1.20.
# This is only injected for 1.20 since CSIServiceAccountToken will be moved to beta starting 1.21.
if [[ $KUBERNETES_VERSION == "1.20"* ]]; then
  KUBELET_CONFIG_WITH_CSI_SERVICE_ACCOUNT_TOKEN_ENABLED=$(cat $WORKING_DIR/kubelet-config.json | jq '.featureGates += {CSIServiceAccountToken: true}')
  echo $KUBELET_CONFIG_WITH_CSI_SERVICE_ACCOUNT_TOKEN_ENABLED > $WORKING_DIR/kubelet-config.json
fi

# Enable Feature Gate for KubeletCredentialProviders in versions less than 1.28 since this feature flag was removed in 1.28.
# TODO: Remove this during 1.27 EOL
if vercmp $KUBERNETES_VERSION lt "1.28"; then
  KUBELET_CONFIG_WITH_KUBELET_CREDENTIAL_PROVIDER_FEATURE_GATE_ENABLED=$(cat $WORKING_DIR/kubelet-config.json | jq '.featureGates += {KubeletCredentialProviders: true}')
  echo $KUBELET_CONFIG_WITH_KUBELET_CREDENTIAL_PROVIDER_FEATURE_GATE_ENABLED > $WORKING_DIR/kubelet-config.json
fi

sudo mv $WORKING_DIR/kubelet.service /etc/systemd/system/kubelet.service
sudo chown root:root /etc/systemd/system/kubelet.service
sudo restorecon /etc/systemd/system/kubelet.service
sudo mv $WORKING_DIR/kubelet-config.json /etc/kubernetes/kubelet/kubelet-config.json
sudo chown root:root /etc/kubernetes/kubelet/kubelet-config.json

sudo systemctl daemon-reload
# Disable the kubelet until the proper dropins have been configured
sudo systemctl disable kubelet

################################################################################
### EKS ########################################################################
################################################################################

sudo mkdir -p /etc/eks
sudo mv $WORKING_DIR/get-ecr-uri.sh /etc/eks/get-ecr-uri.sh
sudo chmod +x /etc/eks/get-ecr-uri.sh
sudo mv $WORKING_DIR/eni-max-pods.txt /etc/eks/eni-max-pods.txt
sudo mv $WORKING_DIR/bootstrap.sh /etc/eks/bootstrap.sh
sudo chmod +x /etc/eks/bootstrap.sh
sudo mv $WORKING_DIR/max-pods-calculator.sh /etc/eks/max-pods-calculator.sh
sudo chmod +x /etc/eks/max-pods-calculator.sh

################################################################################
### ECR CREDENTIAL PROVIDER ####################################################
################################################################################

ECR_CREDENTIAL_PROVIDER_BINARY="ecr-credential-provider"
if [ -n "$AWS_ACCESS_KEY_ID" ] || [ $BINARY_BUCKET_NAME != "amazon-eks" ] || [ $S3_INSTANCE_ROLE = "true" ]; then
  echo "AWS cli present - using it to copy ${ECR_CREDENTIAL_PROVIDER_BINARY} from s3."
  aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$ECR_CREDENTIAL_PROVIDER_BINARY .
else
  echo "AWS cli missing - using wget to fetch ${ECR_CREDENTIAL_PROVIDER_BINARY} from s3. Note: This won't work for private bucket."
  sudo wget "$S3_URL_BASE/$ECR_CREDENTIAL_PROVIDER_BINARY"
fi
sudo chmod +x $ECR_CREDENTIAL_PROVIDER_BINARY
sudo mkdir -p /etc/eks/image-credential-provider
sudo mv $ECR_CREDENTIAL_PROVIDER_BINARY /etc/eks/image-credential-provider/
sudo mv $WORKING_DIR/ecr-credential-provider-config.json /etc/eks/image-credential-provider/config.json

################################################################################
### Cache Images ###############################################################
################################################################################

if [[ "$CACHE_CONTAINER_IMAGES" == "true" ]] && ! [[ " ${ISOLATED_REGIONS[*]} " =~ " ${BINARY_BUCKET_REGION} " ]]; then
  AWS_DOMAIN=$(imds 'latest/meta-data/services/domain')
  ECR_URI=$(/etc/eks/get-ecr-uri.sh "${BINARY_BUCKET_REGION}" "${AWS_DOMAIN}")

  PAUSE_CONTAINER="${ECR_URI}/eks/pause:${PAUSE_CONTAINER_VERSION}"
  cat /etc/eks/containerd/containerd-config.toml | sed s,SANDBOX_IMAGE,$PAUSE_CONTAINER,g | sudo tee /etc/eks/containerd/containerd-cached-pause-config.toml
  sudo cp -v /etc/eks/containerd/containerd-cached-pause-config.toml /etc/containerd/config.toml
  sudo cp -v /etc/eks/containerd/sandbox-image.service /etc/systemd/system/sandbox-image.service
  sudo chown root:root /etc/systemd/system/sandbox-image.service
  sudo systemctl daemon-reload
  sudo systemctl start containerd
  sudo systemctl enable containerd sandbox-image

  K8S_MINOR_VERSION=$(echo "${KUBERNETES_VERSION}" | cut -d'.' -f1-2)

  #### Cache kube-proxy images starting with the addon default version and the latest version
  KUBE_PROXY_ADDON_VERSIONS=$(aws eks describe-addon-versions --addon-name kube-proxy --kubernetes-version=${K8S_MINOR_VERSION})
  KUBE_PROXY_IMGS=()
  if [[ $(jq '.addons | length' <<< $KUBE_PROXY_ADDON_VERSIONS) -gt 0 ]]; then
    DEFAULT_KUBE_PROXY_FULL_VERSION=$(echo "${KUBE_PROXY_ADDON_VERSIONS}" | jq -r '.addons[] .addonVersions[] | select(.compatibilities[] .defaultVersion==true).addonVersion')
    DEFAULT_KUBE_PROXY_VERSION=$(echo "${DEFAULT_KUBE_PROXY_FULL_VERSION}" | cut -d"-" -f1)
    DEFAULT_KUBE_PROXY_PLATFORM_VERSION=$(echo "${DEFAULT_KUBE_PROXY_FULL_VERSION}" | cut -d"-" -f2)

    LATEST_KUBE_PROXY_FULL_VERSION=$(echo "${KUBE_PROXY_ADDON_VERSIONS}" | jq -r '.addons[] .addonVersions[] .addonVersion' | sort -V | tail -n1)
    LATEST_KUBE_PROXY_VERSION=$(echo "${LATEST_KUBE_PROXY_FULL_VERSION}" | cut -d"-" -f1)
    LATEST_KUBE_PROXY_PLATFORM_VERSION=$(echo "${LATEST_KUBE_PROXY_FULL_VERSION}" | cut -d"-" -f2)

    KUBE_PROXY_IMGS=(
      ## Default kube-proxy images
      "${ECR_URI}/eks/kube-proxy:${DEFAULT_KUBE_PROXY_VERSION}-${DEFAULT_KUBE_PROXY_PLATFORM_VERSION}"
      "${ECR_URI}/eks/kube-proxy:${DEFAULT_KUBE_PROXY_VERSION}-minimal-${DEFAULT_KUBE_PROXY_PLATFORM_VERSION}"

      ## Latest kube-proxy images
      "${ECR_URI}/eks/kube-proxy:${LATEST_KUBE_PROXY_VERSION}-${LATEST_KUBE_PROXY_PLATFORM_VERSION}"
      "${ECR_URI}/eks/kube-proxy:${LATEST_KUBE_PROXY_VERSION}-minimal-${LATEST_KUBE_PROXY_PLATFORM_VERSION}"
    )
  fi

  #### Cache VPC CNI images starting with the addon default version and the latest version
  VPC_CNI_ADDON_VERSIONS=$(aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version=${K8S_MINOR_VERSION})
  VPC_CNI_IMGS=()
  if [[ $(jq '.addons | length' <<< $VPC_CNI_ADDON_VERSIONS) -gt 0 ]]; then
    DEFAULT_VPC_CNI_VERSION=$(echo "${VPC_CNI_ADDON_VERSIONS}" | jq -r '.addons[] .addonVersions[] | select(.compatibilities[] .defaultVersion==true).addonVersion')
    LATEST_VPC_CNI_VERSION=$(echo "${VPC_CNI_ADDON_VERSIONS}" | jq -r '.addons[] .addonVersions[] .addonVersion' | sort -V | tail -n1)
    CNI_IMG="${ECR_URI}/amazon-k8s-cni"
    CNI_INIT_IMG="${CNI_IMG}-init"

    VPC_CNI_IMGS=(
      ## Default VPC CNI Images
      "${CNI_IMG}:${DEFAULT_VPC_CNI_VERSION}"
      "${CNI_INIT_IMG}:${DEFAULT_VPC_CNI_VERSION}"

      ## Latest VPC CNI Images
      "${CNI_IMG}:${LATEST_VPC_CNI_VERSION}"
      "${CNI_INIT_IMG}:${LATEST_VPC_CNI_VERSION}"
    )
  fi

  CACHE_IMGS=(
    "${PAUSE_CONTAINER}"
    ${KUBE_PROXY_IMGS[@]+"${KUBE_PROXY_IMGS[@]}"}
    ${VPC_CNI_IMGS[@]+"${VPC_CNI_IMGS[@]}"}
  )
  PULLED_IMGS=()

  for img in "${CACHE_IMGS[@]}"; do
    ## only kube-proxy-minimal is vended for K8s 1.24+
    if [[ "${img}" == *"kube-proxy:"* ]] && [[ "${img}" != *"-minimal-"* ]] && vercmp "${K8S_MINOR_VERSION}" gteq "1.24"; then
      continue
    fi
    ## Since eksbuild.x version may not match the image tag, we need to decrement the eksbuild version until we find the latest image tag within the app semver
    eksbuild_version="1"
    if [[ ${img} == *'eksbuild.'* ]]; then
      eksbuild_version=$(echo "${img}" | grep -o 'eksbuild\.[0-9]\+' | cut -d'.' -f2)
    fi
    ## iterate through decrementing the build version each time
    for build_version in $(seq "${eksbuild_version}" -1 1); do
      img=$(echo "${img}" | sed -E "s/eksbuild.[0-9]+/eksbuild.${build_version}/")
      if /etc/eks/containerd/pull-image.sh "${img}"; then
        PULLED_IMGS+=("${img}")
        break
      elif [[ "${build_version}" -eq 1 ]]; then
        exit 1
      fi
    done
  done

  #### Tag the pulled down image for all other regions in the partition
  for region in $(aws ec2 describe-regions --all-regions | jq -r '.Regions[] .RegionName'); do
    for img in "${PULLED_IMGS[@]}"; do
      regional_img="${img/$BINARY_BUCKET_REGION/$region}"
      sudo ctr -n k8s.io image tag "${img}" "${regional_img}" || :
      ## Tag ECR fips endpoint for supported regions
      if [[ "${region}" =~ (us-east-1|us-east-2|us-west-1|us-west-2|us-gov-east-1|us-gov-west-1) ]]; then
        regional_fips_img="${regional_img/.ecr./.ecr-fips.}"
        sudo ctr -n k8s.io image tag "${img}" "${regional_fips_img}" || :
        sudo ctr -n k8s.io image tag "${img}" "${regional_fips_img/-eksbuild.1/}" || :
      fi
      ## Cache the non-addon VPC CNI images since "v*.*.*-eksbuild.1" is equivalent to leaving off the eksbuild suffix
      if [[ "${img}" == *"-cni"*"-eksbuild.1" ]]; then
        sudo ctr -n k8s.io image tag "${img}" "${regional_img/-eksbuild.1/}" || :
      fi
    done
  done
fi

################################################################################
### SSM Agent ##################################################################
################################################################################

### Set a check here so it can be disabled easily from ImageBuilder
if [ "$INSTALL_SSM_AGENT" = "true" ]; then
  echo "Installing amazon-ssm-agent"
  sudo yum install -y https://s3.${BINARY_BUCKET_REGION}.${S3_DOMAIN}/amazon-ssm-${BINARY_BUCKET_REGION}/${SSM_AGENT_VERSION}/linux_${ARCH}/amazon-ssm-agent.rpm
  sudo systemctl enable amazon-ssm-agent
  sudo systemctl start amazon-ssm-agent
fi

################################################################################
### AMI Metadata ###############################################################
################################################################################

BASE_AMI_ID=$(imds /latest/meta-data/ami-id)
cat << EOF > "${WORKING_DIR}/release"
BASE_AMI_ID="$BASE_AMI_ID"
BUILD_TIME="$(date)"
BUILD_KERNEL="$(uname -r)"
ARCH="$(uname -m)"
EOF
sudo mv "${WORKING_DIR}/release" /etc/eks/release
sudo chown -R root:root /etc/eks

################################################################################
### Stuff required by "protectKernelDefaults=true" #############################
################################################################################

cat << EOF | sudo tee -a /etc/sysctl.d/99-amazon.conf
vm.overcommit_memory=1
kernel.panic=10
kernel.panic_on_oops=1
EOF

################################################################################
### Setting up sysctl properties ###############################################
################################################################################

echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf
echo vm.max_map_count=524288 | sudo tee -a /etc/sysctl.conf

################################################################################
### adding log-collector-script ################################################
################################################################################
sudo mkdir -p /etc/eks/log-collector-script/
# TODO: Find a more elegant solution to this
sudo cp $WORKING_DIR/../log-collector-script/linux/eks-log-collector.sh /etc/eks/log-collector-script/

################################################################################
### Remove Yum Update from cloud-init config ###################################
################################################################################
sudo sed -i \
  's/ - package-update-upgrade-install/# Removed so that nodes do not have version skew based on when the node was started.\n# - package-update-upgrade-install/' \
  /etc/cloud/cloud.cfg

################################################################################
### Change SELinux context for binaries ########################################
################################################################################
sudo semanage fcontext -a -t bin_t -s system_u "/etc/eks(/.*)?"
sudo restorecon -R -vF /etc/eks
sudo semanage fcontext -a -t kubelet_exec_t -s system_u /usr/bin/kubelet
sudo restorecon -vF /usr/bin/kubelet
sudo semanage fcontext -a -t bin_t -s system_u /usr/bin/aws-iam-authenticator
sudo restorecon -vF /usr/bin/aws-iam-authenticator

echo "**************************************************************"
echo "All Done!"
echo "**************************************************************"