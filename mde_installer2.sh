#!/bin/bash



SCRIPT_VERSION="0.6.8"
ASSUMEYES=-y
CHANNEL=
DISTRO=
DISTRO_FAMILY=
PKG_MGR=
INSTALL_MODE=
DEBUG=
VERBOSE=
MDE_VERSION_CMD="mdatp health --field app_version"
PMC_URL=https://packages.microsoft.com/config
SCALED_VERSION=
VERSION=
ONBOARDING_SCRIPT=
OFFBOARDING_SCRIPT=
MIN_REQUIREMENTS=
SKIP_CONFLICTING_APPS=
PASSIVE_MODE=
RTP_MODE=
MIN_CORES=2
MIN_MEM_MB=2048
MIN_DISK_SPACE_MB=1280
tags=()

# Error codes
SUCCESS=0
ERR_INTERNAL=1
ERR_INVALID_ARGUMENTS=2
ERR_INSUFFICIENT_PRIVILAGES=3
ERR_NO_INTERNET_CONNECTIVITY=4
ERR_CONFLICTING_APPS=5
ERR_UNSUPPORTED_DISTRO=10
ERR_UNSUPPORTED_VERSION=11
ERR_INSUFFICIENT_REQUIREMENTS=12
ERR_CORRUPT_MDE_INSTALLED=15
ERR_MDE_NOT_INSTALLED=20
ERR_INSTALLATION_FAILED=21
ERR_UNINSTALLATION_FAILED=22
ERR_FAILED_DEPENDENCY=23
ERR_FAILED_REPO_SETUP=24
ERR_INVALID_CHANNEL=25
ERR_FAILED_REPO_CLEANUP=26
ERR_ONBOARDING_NOT_FOUND=30
ERR_ONBOARDING_FAILED=31
ERR_OFFBOARDING_NOT_FOUND=32
ERR_OFFBOARDING_FAILED=33
ERR_TAG_NOT_SUPPORTED=40
ERR_PARAMETER_SET_FAILED=41
ERR_UNSUPPORTED_ARCH=45

# Predefined values
export DEBIAN_FRONTEND=noninteractive

_log() {
    level="$1"
    dest="$2"
    msg="${@:3}"
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S")

    if [ "$dest" = "stdout" ]; then
       echo "$msg"
    elif [ "$dest" = "stderr" ]; then
       >&2 echo "$msg"
    fi

    if [ -n "$log_path" ]; then
       echo "$ts $level $msg" >> "$log_path"
    fi
}

log_debug() {
    _log "DEBUG" "stdout" "$@"
}

log_info() {
    _log "INFO " "stdout" "$@"
}

log_warning() {
    _log "WARN " "stderr" "$@"
}

log_error() {
    _log "ERROR" "stderr" "$@"
}

script_exit()
{
    if [ -z "$1" ]; then
        log_error "[!] INTERNAL ERROR. script_exit requires an argument"
        exit $ERR_INTERNAL
    fi

    if [ -n "$DEBUG" ]; then
        print_state
    fi

    if [ "$2" = "0" ]; then
        log_info "[v] $1"
    else
        log_error "[x] $1"
    fi

    if [ -z "$2" ]; then
        exit $ERR_INTERNAL
    elif ! [ "$2" -eq "$2" ] 2> /dev/null; then #check error is number
        exit $ERR_INTERNAL
    else
        log_info "[*] exiting ($2)"
        exit $2
    fi
}

get_python() {
   if command -v python3 &> /dev/null; then
      echo "python3"
   elif command -v python2 &> /dev/null; then
      echo "python2"
   else
      echo "python"
   fi
}

parse_uri() {
   cat <<EOF | /usr/bin/env $(get_python)
import sys

if sys.version_info < (3,):
   from urlparse import urlparse
else:
   from urllib.parse import urlparse

uri = urlparse("$1")
print(uri.scheme or "")
print(uri.hostname or "")
print(uri.port or "")
EOF
}

get_rpm_proxy_params() {
    proxy_params=""
    if [ -n "$http_proxy" ]; then
        proxy_host=$(parse_uri "$http_proxy" | sed -n '2p')
        if [ -n "$proxy_host" ];then
           proxy_params="$proxy_params --httpproxy $proxy_host"
        fi

        proxy_port=$(parse_uri "$http_proxy" | sed -n '3p')
        if [ -n "$proxy_port" ]; then
           proxy_params="$proxy_params --httpport $proxy_port"
        fi
    fi
    if [ -n "$ftp_proxy" ];then
       proxy_host=$(parse_uri "$ftp_proxy" | sed -n '2p')
       if [ -n "$proxy_host" ];then
          proxy_params="$proxy_params --ftpproxy $proxy_host"
       fi

       proxy_port=$(parse_uri "$ftp_proxy" | sed -n '3p')
       if [ -n "$proxy_port" ]; then
          proxy_params="$proxy_params --ftpport $proxy_port"
       fi
    fi
    echo $proxy_params
}

run_quietly()
{
    # run_quietly <command> <error_msg> [<error_code>]
    # use error_code for script_exit

    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
        log_error "[!] INTERNAL ERROR. run_quietly requires 2 or 3 arguments"
        exit 1
    fi

    local out=$(eval $1 2>&1; echo "$?")
    local exit_code=$(echo "$out" | tail -n1)

    if [ -n "$VERBOSE" ]; then
        log_info "$out"
    fi
    
    if [ "$exit_code" -ne 0 ]; then
        if [ -n "$DEBUG" ]; then             
            log_debug "[>] Running command: $1"
            log_debug "[>] Command output: $out"
            log_debug "[>] Command exit_code: $exit_code"
        fi

        if [ $# -eq 2 ]; then
            log_error $2
        else
            script_exit "$2" "$3"
        fi
    fi

    return $exit_code
}

retry_quietly()
{
    # retry_quietly <retries> <command> <error_msg> [<error_code>]
    # use error_code for script_exit
    
    if [ $# -lt 3 ] || [ $# -gt 4 ]; then
        log_error "[!] INTERNAL ERROR. retry_quietly requires 3 or 4 arguments"
        exit 1
    fi

    local exit_code=
    local retries=$1

    while [ $retries -gt 0 ]
    do

        if run_quietly "$2" "$3"; then
            exit_code=0
        else
            exit_code=1
        fi
        
        if [ $exit_code -ne 0 ]; then
            sleep 1
            ((retries--))
            log_info "[r] $(($1-$retries))/$1"
        else
            retries=0
        fi
    done

    if [ $# -eq 4 ] && [ $exit_code -ne 0 ]; then
        script_exit "$3" "$4"
    fi

    return $exit_code
}

print_state()
{
    if [ -z $(command -v mdatp) ]; then
        log_warning "[S] MDE not installed."
    else
        log_info "[S] MDE installed."
        if run_quietly "mdatp health" "[S] Could not connect to the daemon -- MDE is not ready to connect yet."; then
            log_info "[S] Version: $($MDE_VERSION_CMD)"
            log_info "[S] Onboarded: $(mdatp health --field licensed)"
            log_info "[S] Passive mode: $(mdatp health --field passive_mode_enabled)"
            log_info "[S] Device tags: $(mdatp health --field edr_device_tags)"
            log_info "[S] Subsystem: $(mdatp health --field real_time_protection_subsystem)"
            log_info "[S] Conflicting applications: $(mdatp health --field conflicting_applications)"
        fi
    fi
}

detect_arch()
{
    arch=$(uname -m)
    if  [[ "$arch" =~ arm* ]]; then
        script_exit "ARM architecture is not yet supported by the script" $ERR_UNSUPPORTED_ARCH
    fi
}

detect_distro()
{
    if [ -f /etc/os-release ] || [ -f /etc/mariner-release ]; then
        . /etc/os-release
        DISTRO=$ID
        VERSION=$VERSION_ID
        VERSION_NAME=$VERSION_CODENAME
    elif [ -f /etc/redhat-release ]; then
        if [ -f /etc/oracle-release ]; then
            DISTRO="ol"
        elif [[ $(grep -o -i "Red\ Hat" /etc/redhat-release) ]]; then
            DISTRO="rhel"
        elif [[ $(grep -o -i "Centos" /etc/redhat-release) ]]; then
            DISTRO="centos"
        fi
        VERSION=$(grep -o "release .*" /etc/redhat-release | cut -d ' ' -f2)
    else
        script_exit "unable to detect distro" $ERR_UNSUPPORTED_DISTRO
    fi

    # change distro to ubuntu for linux mint support
    if [ "$DISTRO" == "linuxmint" ]; then
        DISTRO="ubuntu"
    fi

    if [ "$DISTRO" == "debian" ] || [ "$DISTRO" == "ubuntu" ]; then
        DISTRO_FAMILY="debian"
    elif [ "$DISTRO" == "rhel" ] || [ "$DISTRO" == "centos" ] || [ "$DISTRO" == "ol" ] || [ "$DISTRO" == "fedora" ] || [ "$DISTRO" == "amzn" ] || [ "$DISTRO" == "almalinux" ] || [ "$DISTRO" == "rocky" ]; then
        DISTRO_FAMILY="fedora"
    elif [ "$DISTRO" == "mariner" ]; then
        DISTRO_FAMILY="mariner"
    elif [ "$DISTRO" == "sles" ] || [ "$DISTRO" == "sle-hpc" ] || [ "$DISTRO" == "sles_sap" ]; then
        DISTRO_FAMILY="sles"
    else
        script_exit "unsupported distro $DISTRO $VERSION" $ERR_UNSUPPORTED_DISTRO
    fi

    log_info "[>] detected: $DISTRO $VERSION $VERSION_NAME ($DISTRO_FAMILY)"
}

verify_channel()
{
    if [ "$CHANNEL" != "prod" ] && [ "$CHANNEL" != "insiders-fast" ] && [ "$CHANNEL" != "insiders-slow" ]; then
        script_exit "Invalid channel: $CHANNEL. Please provide valid channel. Available channels are prod, insiders-fast, insiders-slow" $ERR_INVALID_CHANNEL
    fi
}

verify_privileges()
{
    if [ -z "$1" ]; then
        script_exit "Internal error. verify_privileges require a parameter" $ERR_INTERNAL
    fi

    if [ $(id -u) -ne 0 ]; then
        script_exit "root privileges required to perform $1 operation" $ERR_INSUFFICIENT_PRIVILAGES
    fi
}

verify_min_requirements()
{
    # echo "[>] verifying minimal reuirements: $MIN_CORES cores, $MIN_MEM_MB MB RAM, $MIN_DISK_SPACE_MB MB disk space"
    
    local cores=$(nproc --all)
    if [ $cores -lt $MIN_CORES ]; then
        script_exit "MDE requires $MIN_CORES cores or more to run, found $cores." $ERR_INSUFFICIENT_REQUIREMENTS
    fi

    local mem_mb=$(free -m | grep Mem | awk '{print $2}')
    if [ $mem_mb -lt $MIN_MEM_MB ]; then
        script_exit "MDE requires at least $MIN_MEM_MB MB of RAM to run. found $mem_mb MB." $ERR_INSUFFICIENT_REQUIREMENTS
    fi

    local disk_space_mb=$(df -m . | tail -1 | awk '{print $4}')
    if [ $disk_space_mb -lt $MIN_DISK_SPACE_MB ]; then
        script_exit "MDE requires at least $MIN_DISK_SPACE_MB MB of free disk space for installation. found $disk_space_mb MB." $ERR_INSUFFICIENT_REQUIREMENTS
    fi

    log_info "[v] minimal requirements met"
}

find_service()
{
    if [ -z "$1" ]; then
        script_exit "INTERNAL ERROR.
