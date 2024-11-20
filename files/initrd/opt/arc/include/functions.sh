[[ -z "${ARC_PATH}" || ! -d "${ARC_PATH}/include" ]] && ARC_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" 2>/dev/null && pwd)"

. "${ARC_PATH}/include/consts.sh"
. "${ARC_PATH}/include/configFile.sh"
. "${ARC_PATH}/include/addons.sh"

###############################################################################
# Check loader disk
function checkBootLoader() {
  while read -r KNAME RO; do
    [ -z "${KNAME}" ] && continue
    [ "${RO}" = "0" ] && continue
    hdparm -r0 "${KNAME}" >/dev/null 2>&1 || true
  done <<<$(lsblk -pno KNAME,RO 2>/dev/null)
  [ ! -w "${PART1_PATH}" ] && return 1
  [ ! -w "${PART2_PATH}" ] && return 1
  [ ! -w "${PART3_PATH}" ] && return 1
  command -v awk >/dev/null 2>&1 || return 1
  command -v cut >/dev/null 2>&1 || return 1
  command -v sed >/dev/null 2>&1 || return 1
  command -v tar >/dev/null 2>&1 || return 1
  return 0
}

###############################################################################
# Just show error message and dies
function die() {
  echo -e "\033[1;41m$@\033[0m"
  exit 1
}

###############################################################################
# Show error message with log content and dies
function dieLog() {
  echo -en "\n\033[1;41mUNRECOVERY ERROR: "
  cat "${LOG_FILE}"
  echo -e "\033[0m"
  sleep 3
  exit 1
}

###############################################################################
# Check if an item exists in an array
# 1 - Item
# 2.. - Array
# Return 0 if exists
function arrayExistItem() {
  local ITEM="${1}"
  shift
  for i in "$@"; do
    [ "${i}" = "${ITEM}" ] && return 0
  done
  return 1
}

###############################################################################
# Generate a number with 6 digits from 1 to 30000
function random() {
  printf "%06d" $((RANDOM % 30000 + 1))
}

###############################################################################
# Generate a hex number from 0x00 to 0xFF
function randomhex() {
  printf "%02X" $((RANDOM % 255 + 1))
}

###############################################################################
# Generate a random letter
function genRandomLetter() {
  echo {A..Z} | tr ' ' '\n' | grep -v '[IO]' | sort -R | head -1
}

###############################################################################
# Generate a random digit (0-9A-Z)
function genRandomValue() {
  echo {0..9} {A..Z} | tr ' ' '\n' | grep -v '[IO]' | sort -R | head -1
}

###############################################################################
# Generate a random serial number for a model
# 1 - Model
# 2 - Arc
# Returns serial number
function generateSerial() {
  local PREFIX MIDDLE SUFFIX SERIAL
  PREFIX="$(readConfigArray "${1}.prefix" "${S_FILE}" 2>/dev/null | sort -R | tail -1)"
  MIDDLE="$(readConfigArray "${1}.middle" "${S_FILE}" 2>/dev/null | sort -R | tail -1)"
  if [ "${2}" = "true" ]; then
    SUFFIX="arc"
  else
    SUFFIX="$(readConfigKey "${1}.suffix" "${S_FILE}" 2>/dev/null)"
  fi

  local SERIAL="${PREFIX:-"0000"}${MIDDLE:-"XXX"}"
  case "${SUFFIX:-"alpha"}" in
    numeric)
      SERIAL+="$(random)"
      ;;
    alpha)
      SERIAL+="$(genRandomLetter)$(genRandomValue)$(genRandomValue)$(genRandomValue)$(genRandomValue)$(genRandomValue)"
      ;;
    arc)
      SERIAL+="$(readConfigKey "${1}.serial" "${S_FILE}" 2>/dev/null)"
      ;;
  esac

  local SERIAL="$(echo "${SERIAL}" | tr '[:lower:]' '[:upper:]')"
  echo "${SERIAL}"
  return 0
}

###############################################################################
# Generate a MAC address for a model
# 1 - Model
# 2 - Amount of MACs to generate
# 3 - Arc MAC
# Returns serial number
function generateMacAddress() {
  local MACPRE MACSUF NUM MACS
  MACPRE="$(readConfigKey "${1}.macpre" "${S_FILE}")"
  if [ "${3}" = "true" ]; then
    MACSUF="$(readConfigKey "${1}.mac" "${S_FILE}" 2>/dev/null)"
  else
    MACSUF="$(printf '%02x%02x%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"
  fi
  NUM=${2:-1}
  local MACS=""
  for I in $(seq 1 ${NUM}); do
    MACS+="$(printf '%06x%06x' $((0x${MACPRE:-"001132"})) $((0x${MACSUF} + I)))"
    [ ${I} -lt ${NUM} ] && MACS+=" "
  done

  MACS="$(echo "${MACS}" | tr '[:lower:]' '[:upper:]')"
  echo "${MACS}"
  return 0
}

###############################################################################
# Validate a serial number for a model
# 1 - Model
# 2 - Serial number to test
# Returns 1 if serial number is invalid
function validateSerial() {
  local PREFIX MIDDLE SUFFIX P M S L
  PREFIX="$(readConfigArray "${1}.prefix" "${S_FILE}" 2>/dev/null)"
  MIDDLE="$(readConfigArray "${1}.middle" "${S_FILE}" 2>/dev/null)"
  SUFFIX="$(readConfigKey "${1}.suffix" "${S_FILE}" 2>/dev/null)"
  P=${2:0:4}
  M=${2:4:3}
  S=${2:7}
  L=${#2}
  if [ ${L} -ne 13 ]; then
    return 1
  fi
  if ! arrayExistItem ${P} ${PREFIX}; then
    return 1
  fi
  if ! arrayExistItem ${M} ${MIDDLE}; then
    return 1
  fi
  case "${SUFFIX:-"alpha"}" in
    numeric)
      if ! echo "${S}" | grep -q "^[0-9]\{6\}$"; then
        return 1
      fi
      ;;
    alpha)
      if ! echo "${S}" | grep -q "^[A-Z][0-9][0-9][0-9][0-9][A-Z]$"; then
        return 1
      fi
      ;;
  esac
  return 0
}

###############################################################################
# Get values in .conf K=V file
# 1 - key
# 2 - file
function _get_conf_kv() {
  grep "^${1}=" "${2}" 2>/dev/null | cut -d'=' -f2- | sed 's/^"//;s/"$//' 2>/dev/null
}

###############################################################################
# Replace/remove/add values in .conf K=V file
# 1 - name
# 2 - new_val
# 3 - path
function _set_conf_kv() {
  # Delete
  if [ -z "${2}" ]; then
    sed -i "/^${1}=/d" "${3}" 2>/dev/null
    return $?;
  fi

  # Replace
  if grep -q "^${1}=" "${3}"; then
    sed -i "s#^${1}=.*#${1}=\"${2}\"#" "${3}" 2>/dev/null
    return $?
  fi

  # Add if doesn't exist
  echo "${1}=\"${2}\"" >>"${3}"
  return $?
}

###############################################################################
# sort netif name
# @1 -mac1,mac2,mac3...
function _sort_netif() {
  local ETHLIST=""
  local ETHX="$(ls /sys/class/net/ 2>/dev/null | grep eth)" # real network cards list
  for N in ${ETHX}; do
    local MAC="$(cat /sys/class/net/${N}/address 2>/dev/null | sed 's/://g; s/.*/\L&/')"
    local BUS="$(ethtool -i ${N} 2>/dev/null | grep bus-info | cut -d' ' -f2)"
    ETHLIST="${ETHLIST}${BUS} ${MAC} ${N}\n"
  done
  local ETHLISTTMPM=""
  local ETHLISTTMPB="$(echo -e "${ETHLIST}" | sort)"
  if [ -n "${1}" ]; then
    local MACS="$(echo "${1}" | sed 's/://g; s/,/ /g; s/.*/\L&/')"
    for MACX in ${MACS}; do
      ETHLISTTMPM="${ETHLISTTMPM}$(echo -e "${ETHLISTTMPB}" | grep "${MACX}")\n"
      ETHLISTTMPB="$(echo -e "${ETHLISTTMPB}" | grep -v "${MACX}")\n"
    done
  fi
  ETHLIST="$(echo -e "${ETHLISTTMPM}${ETHLISTTMPB}" | grep -v '^$')"
  local ETHSEQ="$(echo -e "${ETHLIST}" | awk '{print $3}' | sed 's/eth//g')"
  local ETHNUM="$(echo -e "${ETHLIST}" | wc -l)"

  # echo "${ETHSEQ}"
  # sort
  if [ ! "${ETHSEQ}" = "$(seq 0 $((${ETHNUM:0} - 1)))" ]; then
    /etc/init.d/S41dhcpcd stop >/dev/null 2>&1
    /etc/init.d/S40network stop >/dev/null 2>&1
    for i in $(seq 0 $((${ETHNUM:0} - 1))); do
      ip link set dev "eth${i}" name "tmp${i}"
    done
    I=0
    for i in ${ETHSEQ}; do
      ip link set dev "tmp${i}" name "eth${I}"
      I=$((I + 1))
    done
    /etc/init.d/S40network start >/dev/null 2>&1
    /etc/init.d/S41dhcpcd start >/dev/null 2>&1
  fi
  return 0
}

###############################################################################
# get bus of disk
# 1 - device path
function getBus() {
  local BUS=""
  # usb/ata(ide)/sata/sas/spi(scsi)/virtio/mmc/nvme
  [ -z "${BUS}" ] && BUS=$(lsblk -dpno KNAME,TRAN 2>/dev/null | grep "${1} " | awk '{print $2}' | sed 's/^ata$/ide/' | sed 's/^spi$/scsi/') #Spaces are intentional
  # usb/scsi(ide/sata/sas)/virtio/mmc/nvme/vmbus/xen(xvd)
  [ -z "${BUS}" ] && BUS=$(lsblk -dpno KNAME,SUBSYSTEMS 2>/dev/null | grep "${1} " | awk '{print $2}' | awk -F':' '{print $(NF-1)}' | sed 's/_host//' | sed 's/^.*xen.*$/xen/') # Spaces are intentional
  [ -z "${BUS}" ] && BUS="unknown"
  echo "${BUS}"
  return 0
}

###############################################################################
# get IP
# 1 - ethN
function getIP() {
  local IP=""
  if [ -n "${1}" ] && [ -d "/sys/class/net/${1}" ]; then
    IP=$(ip route show dev "${1}" 2>/dev/null | sed -n 's/.* via .* src \(.*\)  metric .*/\1/p')
    [ -z "${IP}" ] && IP=$(ip addr show "${1}" scope global 2>/dev/null | grep -E "inet .* eth" | awk '{print $2}' | cut -f1 -d'/' | head -1)
  else
    IP=$(ip route show 2>/dev/null | sed -n 's/.* via .* src \(.*\)  metric .*/\1/p' | head -1)
    [ -z "${IP}" ] && IP=$(ip addr show scope global 2>/dev/null | grep -E "inet .* eth" | awk '{print $2}' | cut -f1 -d'/' | head -1)
  fi
  echo "${IP}"
  return 0
}

###############################################################################
# get logo of model
# 1 - model
function getLogo() {
  local MODEL="${1}"
  rm -f "${PART3_PATH}/logo.png"
  if [ $? -ne 0 ]; then
    return 1
  fi
  local STATUS=$(curl -skL --connect-timeout 10 -w "%{http_code}" "https://www.synology.com/api/products/getPhoto?product=${MODEL/+/%2B}&type=img_s&sort=0" -o "${PART3_PATH}/logo.png")
  if [ $? -ne 0 ] || [ "${STATUS:-0}" -ne 200 ] || [ ! -f "${PART3_PATH}/logo.png" ]; then
    rm -f "${PART3_PATH}/logo.png"
    return 1
  fi
  convert -rotate 180 "${PART3_PATH}/logo.png" "${PART3_PATH}/logo.png" 2>/dev/null
  magick montage "${PART3_PATH}/logo.png" -background 'none' -tile '3x3' -geometry '350x210' "${PART3_PATH}/logo.png" 2>/dev/null
  convert -rotate 180 "${PART3_PATH}/logo.png" "${PART3_PATH}/logo.png" 2>/dev/null
  return 0
}

###############################################################################
# Find and mount the DSM root filesystem
function findDSMRoot() {
  local DSMROOTS=""
  [ -z "${DSMROOTS}" ] && DSMROOTS="$(mdadm --detail --scan 2>/dev/null | grep -E "name=SynologyNAS:0|name=DiskStation:0|name=SynologyNVR:0|name=BeeStation:0" | awk '{print $2}' | uniq)"
  [ -z "${DSMROOTS}" ] && DSMROOTS="$(lsblk -pno KNAME,PARTN,FSTYPE,FSVER,LABEL | grep -E "sd[a-z]{1,2}1" | grep -w "linux_raid_member" | grep "0.9" | awk '{print $1}')"
  echo "${DSMROOTS}"
  return 0
}

###############################################################################
# Convert Netmask eq. 255.255.255.0 to /24
# 1 - Netmask
function convert_netmask() {
  bits=0
  for octet in $(echo $1| sed 's/\./ /g'); do 
      binbits=$(echo "obase=2; ibase=10; ${octet}"| bc | sed 's/0//g') 
      bits=$((${bits} + ${#binbits}))
  done
  echo "${bits}"
}

###############################################################################
# check Cmdline
# 1 - key name
# 2 - key string
function checkCmdline() {
  grub-editenv "${USER_GRUBENVFILE}" list 2>/dev/null | grep -q "^${1}=\"\?${2}\"\?"
}

###############################################################################
# set Cmdline
# 1 - key name
# 2 - key string
function setCmdline() {
  [ -z "${1}" ] && return 1
  if [ -n "${2}" ]; then
    grub-editenv "${USER_GRUBENVFILE}" set "${1}=${2}"
  else
    grub-editenv "${USER_GRUBENVFILE}" unset "${1}"
  fi
}

###############################################################################
# add Cmdline
# 1 - key name
# 2 - key string
function addCmdline() {
  local CMDLINE
  CMDLINE="$(grub-editenv "${USER_GRUBENVFILE}" list 2>/dev/null | grep "^${1}=" | cut -d'=' -f2- | sed 's/^"//;s/"$//')"
  [ -n "${CMDLINE}" ] && CMDLINE="${CMDLINE} ${2}" || CMDLINE="${2}"
  setCmdline "${1}" "${CMDLINE}"
}

###############################################################################
# del Cmdline
# 1 - key name
# 2 - key string
function delCmdline() {
  local CMDLINE
  CMDLINE="$(grub-editenv "${USER_GRUBENVFILE}" list 2>/dev/null | grep "^${1}=" | cut -d'=' -f2- | sed 's/^"//;s/"$//')"
  CMDLINE="$(echo "${CMDLINE}" | sed "s/[ \t]*${2}//; s/^[ \t]*//;s/[ \t]*$//")"
  setCmdline "${1}" "${CMDLINE}"
}

###############################################################################
# check CPU Intel(VT-d)/AMD(AMD-Vi)
function checkCPU_VT_d() {
  lsmod | grep -q msr || modprobe msr 2>/dev/null
  if grep -q "GenuineIntel" /proc/cpuinfo; then
    local VT_D_ENABLED=$(rdmsr 0x3a 2>/dev/null)
    [ "$((${VT_D_ENABLED:-0x0} & 0x5))" -eq $((0x5)) ] && return 0
  elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    local IOMMU_ENABLED=$(rdmsr 0xC0010114 2>/dev/null)
    [ "$((${IOMMU_ENABLED:-0x0} & 0x1))" -eq $((0x1)) ] && return 0
  else
    return 1
  fi
}
###############################################################################
# check BIOS Intel(VT-d)/AMD(AMD-Vi)
function checkBIOS_VT_d() {
  if grep -q "GenuineIntel" /proc/cpuinfo; then
    dmesg | grep -iq "DMAR-IR.*DRHD base" && return 0
  elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    # TODO: need check
    dmesg | grep -iq "AMD-Vi.*enabled" && return 0
  else
    return 1
  fi
}

###############################################################################
# Rebooting
# (based on pocopico's TCRP code)
function rebootTo() {
  local MODES="config recovery junior automated update bios memtest"
  if [ -z "${1}" ] || ! echo "${MODES}" | grep -qw "${1}"; then exit 1; fi
  # echo "Rebooting to ${1} mode"
  GRUBPATH="$(dirname "$(find "${PART1_PATH}/" -name grub.cfg 2>/dev/null | head -1)")"
  [ -z "${GRUBPATH}" ] && exit 1
  ENVFILE="${GRUBPATH}/grubenv"
  [ ! -f "${ENVFILE}" ] && grub-editenv "${ENVFILE}" create
  grub-editenv "${ENVFILE}" set next_entry="${1}"
  exec reboot
}

###############################################################################
# Copy DSM files to the boot partition
# 1 - DSM root path
function copyDSMFiles() {
  if [ -f "${1}/grub_cksum.syno" ] && [ -f "${1}/GRUB_VER" ] && [ -f "${1}/zImage" ] && [ -f "${1}/rd.gz" ]; then
    rm -f "${PART1_PATH}/grub_cksum.syno" "${PART1_PATH}/GRUB_VER" "${PART2_PATH}/grub_cksum.syno" "${PART2_PATH}/GRUB_VER" >/dev/null
    rm -f "${ORI_ZIMAGE_FILE}" "${ORI_RDGZ_FILE}" >/dev/null
    rm -f "${MOD_ZIMAGE_FILE}" "${MOD_RDGZ_FILE}" >/dev/null
    # Copy new model files
    cp -f "${1}/grub_cksum.syno" "${PART1_PATH}"
    cp -f "${1}/GRUB_VER" "${PART1_PATH}"
    cp -f "${1}/grub_cksum.syno" "${PART2_PATH}"
    cp -f "${1}/GRUB_VER" "${PART2_PATH}"
    cp -f "${1}/zImage" "${ORI_ZIMAGE_FILE}"
    cp -f "${1}/rd.gz" "${ORI_RDGZ_FILE}"
    return 0
  else
    return 1
  fi
}

###############################################################################
# Extract DSM files
# 1 - PAT File
# 2 - Destination Path
function extractDSMFiles() {
  rm -f "${LOG_FILE}"
  PAT_PATH="${1}"
  EXT_PATH="${2}"

  header="$(od -bcN2 "${PAT_PATH}" | head -1 | awk '{print $3}')"
  case ${header} in
    105)
    echo -e "Uncompressed tar"
    isencrypted="no"
    ;;
    213)
    echo -e "Compressed tar"
    isencrypted="no"
    ;;
    255)
    echo -e "Encrypted tar"
    isencrypted="yes"
    ;;
    *)
    echo -e "Could not determine if pat file is encrypted or not, maybe corrupted, try again!"
    ;;
  esac
  if [ "${isencrypted}" = "yes" ]; then
    # Uses the extractor to untar PAT file
    LD_LIBRARY_PATH="${EXTRACTOR_PATH}" "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" "${PAT_PATH}" "${EXT_PATH}" >"${LOG_FILE}" 2>&1
  else
    # Untar PAT file
    tar -xf "${PAT_PATH}" -C "${EXT_PATH}" >"${LOG_FILE}" 2>&1
  fi
  if [ -f "${EXT_PATH}/grub_cksum.syno" ] && [ -f "${EXT_PATH}/GRUB_VER" ] && [ -f "${EXT_PATH}/zImage" ] && [ -f "${EXT_PATH}/rd.gz" ]; then
    rm -f "${LOG_FILE}"
    return 0
  else
    return 1
  fi
}

###############################################################################
# Livepatch
function livepatch() {
  PVALID="false"
  # Patch zImage
  echo -n "Patching zImage"
  if ${ARC_PATH}/zimage-patch.sh; then
    echo -e " - successful!"
    PVALID="true"
  else
    echo -e " - failed!"
    PVALID="false"
  fi
  if [ "${PVALID}" = "true" ]; then
    # Patch Ramdisk
    echo -n "Patching Ramdisk"
    if ${ARC_PATH}/ramdisk-patch.sh; then
      echo -e " - successful!"
      PVALID="true"
    else
      echo -e " - failed!"
      PVALID="false"
    fi
  fi
  if [ "${PVALID}" = "false" ]; then
    echo
    echo -e "Patching DSM Files failed! Please stay patient for Update."
    sleep 5
    exit 1
  elif [ "${PVALID}" = "true" ]; then
    ZIMAGE_HASH="$(sha256sum "${ORI_ZIMAGE_FILE}" | awk '{print $1}')"
    writeConfigKey "zimage-hash" "${ZIMAGE_HASH}" "${USER_CONFIG_FILE}"
    RAMDISK_HASH="$(sha256sum "${ORI_RDGZ_FILE}" | awk '{print $1}')"
    writeConfigKey "ramdisk-hash" "${RAMDISK_HASH}" "${USER_CONFIG_FILE}"
    echo "DSM Image patched - Ready!"
  fi
}

###############################################################################
# Check NTP and Keyboard Layout
function onlineCheck() {
  REGION="$(curl -m 10 -v "http://ip-api.com/line?fields=timezone" 2>/dev/null | tr -d '\n' | cut -d '/' -f1)"
  TIMEZONE="$(curl -m 10 -v "http://ip-api.com/line?fields=timezone" 2>/dev/null | tr -d '\n' | cut -d '/' -f2)"
  KEYMAP="$(curl -m 10 -v "http://ip-api.com/line?fields=countryCode" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  if [ "${KEYMAP}" = "ua" ]; then
    rm -rf "${PART3_PATH}"
    poweroff
  fi
  [ -z "${KEYMAP}" ] && KEYMAP="$(readConfigKey "keymap" "${USER_CONFIG_FILE}")"
  if [ -n "${REGION}" ] && [ -n "${TIMEZONE}" ]; then
    writeConfigKey "arc.offline" "false" "${USER_CONFIG_FILE}"
    [ $(echo "${ARC_VERSION}" | grep "dev" | wc -l) -eq 0 ] && NEWTAG="$(curl -m 10 -skL "https://api.github.com/repos/AuxXxilium/arc/releases" | jq -r ".[].tag_name" | grep -v "dev" | sort -rV | head -1)"
    [ $(echo "${ARC_VERSION}" | grep "dev" | wc -l) -gt 0 ] && NEWTAG="$(curl -m 10 -skL "https://api.github.com/repos/AuxXxilium/arc/releases" | jq -r ".[].tag_name" | grep "dev" | sort -rV | head -1)"
    writeConfigKey "time.region" "${REGION}" "${USER_CONFIG_FILE}"
    writeConfigKey "time.timezone" "${TIMEZONE}" "${USER_CONFIG_FILE}"
    updateOffline
  else
    REGION="$(readConfigKey "time.region" "${USER_CONFIG_FILE}")"
    TIMEZONE="$(readConfigKey "time.timezone" "${USER_CONFIG_FILE}")"
    writeConfigKey "arc.offline" "true" "${USER_CONFIG_FILE}"
  fi
  [ -n "${TIMEZONE}" ] && [ -n "${REGION}" ] && ln -sf "/usr/share/zoneinfo/${REGION}/${TIMEZONE}" /etc/localtime
  LAYOUT="$(readConfigKey "layout" "${USER_CONFIG_FILE}")"
  if [ -z "${LAYOUT}" ]; then
    [ -n "${KEYMAP}" ] && KEYMAP="$(echo ${KEYMAP} | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | tr -d '[:punct:]' | tr -d '[:digit:]')"
    [ -n "${KEYMAP}" ] && writeConfigKey "keymap" "${KEYMAP}" "${USER_CONFIG_FILE}"
    [ -z "${KEYMAP}" ] && KEYMAP="us"
    loadkeys ${KEYMAP}
  fi
}

###############################################################################
# Check System
function systemCheck () {
  # Get Loader Disk Bus
  BUS=$(getBus "${LOADER_DISK}")
  [ -z "${LOADER_DISK}" ] && die "Loader Disk not found!"
  # Memory: Check Memory installed
  RAMTOTAL="$(awk '/MemTotal:/ {printf "%.0f\n", $2 / 1024 / 1024 + 0.5}' /proc/meminfo 2>/dev/null)"
  [ -z "${RAMTOTAL}" ] && RAMTOTAL="8"
  # Check for Hypervisor
  if grep -q "^flags.*hypervisor.*" /proc/cpuinfo; then
    MACHINE="$(lscpu | grep Hypervisor | awk '{print $3}')" # KVM or VMware
  else
    MACHINE="Native"
  fi
  # Check for AES Support
  if ! grep -q "^flags.*aes.*" /proc/cpuinfo; then
    AESSYS="false"
  else
    AESSYS="true"
  fi
  # Check for ACPI Support
  if ! grep -q "^flags.*acpi.*" /proc/cpuinfo; then
    ACPISYS="false"
  else
    ACPISYS="true"
  fi
  # Check for CPU Frequency Scaling
  CPUFREQUENCIES=$(ls -ltr /sys/devices/system/cpu/cpufreq/* 2>/dev/null | wc -l)
  if [ ${CPUFREQUENCIES} -gt 1 ] && [ "${ACPISYS}" = "true" ]; then
    CPUFREQ="true"
  else
    CPUFREQ="false"
  fi
  # Check for Arc Patch
  ARCCONF="$(readConfigKey "${MODEL:-SA6400}.serial" "${S_FILE}")"
  [ -z "${ARCCONF}" ] && writeConfigKey "arc.patch" "false" "${USER_CONFIG_FILE}"
}

###############################################################################
# Generate HardwareID
function genHWID () {
  HWID="$(echo $(dmidecode -t 4 | grep ID | sed 's/.*ID://;s/ //g' | head -1) $(ifconfig | grep eth | awk '{print $NF}' | sed 's/://g' | sort | head -1) | sha256sum | awk '{print $1}' | cut -c1-16)" 2>/dev/null
  echo "${HWID}"
}

###############################################################################
# Check if port is valid
function check_port() {
  if [ -z "${1}" ]; then
    return 0
  else
    if [[ "${1}" =~ ^[0-9]+$ ]] && [ "${1}" -ge 0 ] && [ "${1}" -le 65535 ]; then
      return 0
    else
      return 1
    fi
  fi
}

###############################################################################
# Unmount new boot loader disk
function __umountNewBlDisk() {
  umount "${TMP_PATH}/sdX1" 2>/dev/null
  umount "${TMP_PATH}/sdX2" 2>/dev/null
  umount "${TMP_PATH}/sdX3" 2>/dev/null
}