#!/usr/bin/env bash
# NVIDIA driver installer for AWS EC2 g4dn.xlarge (Tesla T4), Ubuntu 22.04/24.04 x86_64.
# Integrated from the user-provided script. Ansible invokes it with --no-reboot and
# manages reboot itself. Optional flags: --cuda, --docker, --no-reboot.
set -Eeuo pipefail

LOG_FILE=/var/log/setup-nvidia.log
INSTALL_CUDA=0
INSTALL_DOCKER=0
AUTO_REBOOT=1
CUDA_TOOLKIT_PKG="${CUDA_TOOLKIT_PKG:-}"
for arg in "$@"; do
  case "$arg" in
    --cuda) INSTALL_CUDA=1 ;;
    --docker) INSTALL_DOCKER=1 ;;
    --no-reboot) AUTO_REBOOT=0 ;;
    -h|--help) sed -n '1,8p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done
log()  { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "[x] Script failed at line ${LINENO}; see ${LOG_FILE}" >&2' ERR

. /etc/os-release
[[ "${ID}" == ubuntu ]] || die "Ubuntu required (found ${ID})"
case "${VERSION_ID}" in 22.04|24.04) ;; *) warn "Ubuntu ${VERSION_ID} is not explicitly tested; intended target is 22.04/24.04" ;; esac
[[ "$(uname -m)" == x86_64 ]] || die "Expected x86_64, got $(uname -m)"
if [[ "$(uname -r)" != *-aws ]]; then warn "Kernel $(uname -r) is not linux-aws; DKMS may take longer or require headers."; fi
FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
MIN_FREE_GB=6
if (( INSTALL_CUDA || INSTALL_DOCKER )); then MIN_FREE_GB=20; fi
(( FREE_GB >= MIN_FREE_GB )) || die "Free space ${FREE_GB}GB; need at least ${MIN_FREE_GB}GB on /"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT_OPTS=(-y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt_get() { apt-get "${APT_OPTS[@]}" "$@"; }
retry() { local n=$1 i; shift; for ((i=1;i<=n;i++)); do "$@" && return 0; warn "Attempt ${i}/${n} failed: $*"; sleep $((i*10)); done; return 1; }
wait_for_apt() {
  log "Waiting for cloud-init and apt/dpkg locks"
  if command -v cloud-init >/dev/null 2>&1; then timeout 600 cloud-init status --wait >/dev/null 2>&1 || true; fi
  if ! command -v fuser >/dev/null 2>&1; then
    warn "fuser is unavailable before base packages are installed; apt-get lock timeout remains enabled."
    return 0
  fi
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    (( waited < 600 )) || die "apt/dpkg lock held for more than 10 minutes"
    sleep 5; waited=$((waited+5))
  done
}
install_driver_fallback() {
  local b
  local -a branches=()
  mapfile -t branches < <(apt-cache pkgnames nvidia-headless- 2>/dev/null | sed -n 's/^nvidia-headless-\([0-9][0-9]*\)-server$/\1/p' | sort -rn)
  for b in "${branches[@]}"; do
    if apt-cache show "nvidia-headless-${b}-server" >/dev/null 2>&1 && apt-cache show "nvidia-utils-${b}-server" >/dev/null 2>&1; then
      log "Fallback: installing nvidia-headless-${b}-server and nvidia-utils-${b}-server"
      apt_get install "nvidia-headless-${b}-server" "nvidia-utils-${b}-server" && return 0
    fi
  done
  return 1
}

wait_for_apt
log "Updating packages"
retry 3 apt_get update
apt_get upgrade
log "Installing base dependencies"
apt_get install build-essential dkms pciutils lshw curl ca-certificates gnupg psmisc ubuntu-drivers-common
if [[ "$(uname -r)" == *-aws ]]; then apt_get install linux-headers-aws || warn "linux-headers-aws could not be installed"; fi
apt_get install "linux-headers-$(uname -r)" || warn "Headers for current kernel unavailable; DKMS may fail if prebuilt modules are unavailable"
log "Checking for NVIDIA PCI device"
PCI_INFO=$(lspci -nn 2>/dev/null | grep -i nvidia || true)
[[ -n "${PCI_INFO}" ]] || die "No NVIDIA GPU detected. This script targets AWS EC2 g4dn.* (not g4ad)."
echo "${PCI_INFO}"
log "Installing NVIDIA driver via ubuntu-drivers --gpgpu"
ubuntu-drivers list --gpgpu || true
if ! retry 3 ubuntu-drivers install --gpgpu || ! command -v nvidia-smi >/dev/null 2>&1; then
  warn "ubuntu-drivers did not install a usable driver; trying server packages"
  install_driver_fallback || die "Could not install NVIDIA driver"
fi
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found after driver installation"
DRV_BRANCH=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-utils-*' 2>/dev/null | awk '/^ii/ {print $2}' | grep -oE '[0-9]+' | sort -n | tail -1 || true)
log "Installed driver branch: ${DRV_BRANCH:-unknown}"

if (( INSTALL_CUDA )); then
  if [[ -z "${CUDA_TOOLKIT_PKG}" ]]; then
    if [[ -n "${DRV_BRANCH}" ]] && (( DRV_BRANCH < 570 )); then CUDA_TOOLKIT_PKG=cuda-toolkit-12-2; else CUDA_TOOLKIT_PKG=cuda-toolkit-12-8; fi
  fi
  log "Installing CUDA Toolkit ${CUDA_TOOLKIT_PKG} from NVIDIA repository"
  UBU_NODOT="${VERSION_ID//./}"
  KEYRING_DEB=/tmp/cuda-keyring.deb
  retry 3 curl -fsSL -o "${KEYRING_DEB}" "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBU_NODOT}/x86_64/cuda-keyring_1.1-1_all.deb"
  dpkg -i "${KEYRING_DEB}"; rm -f "${KEYRING_DEB}"
  retry 3 apt_get update
  apt_get install "${CUDA_TOOLKIT_PKG}"
  CUDA_DIR=$(find /usr/local -maxdepth 1 -type d -name 'cuda-*' | sort -V | tail -1 || true)
  if [[ -n "${CUDA_DIR}" ]]; then
    cat > /etc/profile.d/cuda.sh <<PROFILE
export PATH=${CUDA_DIR}/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=${CUDA_DIR}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
PROFILE
  fi
fi

if (( INSTALL_DOCKER )); then
  log "Installing Docker (optional script path)"
  if ! command -v docker >/dev/null 2>&1; then retry 3 curl -fsSL -o /tmp/get-docker.sh https://get.docker.com; sh /tmp/get-docker.sh; rm -f /tmp/get-docker.sh; fi
  if [[ -n "${SUDO_USER:-}" ]]; then usermod -aG docker "${SUDO_USER}" || true; fi
  log "Installing NVIDIA Container Toolkit (optional script path)"
  install -d -m 0755 /usr/share/keyrings
  retry 3 curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /tmp/nvidia-ct.gpgkey
  gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg /tmp/nvidia-ct.gpgkey; rm -f /tmp/nvidia-ct.gpgkey
  retry 3 curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o /tmp/nvidia-ct.list
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' /tmp/nvidia-ct.list > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  rm -f /tmp/nvidia-ct.list
  retry 3 apt_get update; apt_get install nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi
log "Enabling nvidia-persistenced (if available)"
systemctl enable nvidia-persistenced 2>/dev/null || warn "nvidia-persistenced unavailable; continuing"
log "Installation completed; log: ${LOG_FILE}"
echo "Next: reboot, then run nvidia-smi."
if (( INSTALL_CUDA )); then echo "CUDA check: nvcc --version (after a new login)"; fi
if (( INSTALL_DOCKER )); then echo "Container GPU check: docker run --rm --gpus all nvidia/cuda:12.2.2-base-ubuntu22.04 nvidia-smi"; fi
if (( AUTO_REBOOT )); then warn "Rebooting in 10 seconds (Ctrl+C to cancel)"; sync; sleep 10; reboot; fi
