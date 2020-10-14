#!/bin/bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

# This script holds commons function used in XDP Testcases

pktgenResult=""

function get_vf_name() {
    local nicName=$1
    local ignoreIF=$(ip route | grep default | awk '{print $5}')
    local interfaces=$(ls /sys/class/net | grep -v lo | grep -v ${ignoreIF})
    local synthIFs=""
    local vfIFs=""
    local interface
    for interface in ${interfaces}; do
        # alternative is, but then must always know driver name
        # readlink -f /sys/class/net/<interface>/device/driver/
        local bus_addr=$(ethtool -i ${interface} | grep bus-info | awk '{print $2}')
        if [ -z "${bus_addr}" ]; then
            synthIFs="${synthIFs} ${interface}"
        else
            vfIFs="${vfIFs} ${interface}"
        fi
    done

    local vfIF
    local synthMAC=$(ip link show $nicName | grep ether | awk '{print $2}')
    for vfIF in ${vfIFs}; do
        local vfMAC=$(ip link show ${vfIF} | grep ether | awk '{print $2}')
        # single = is posix compliant
        if [ "${synthMAC}" = "${vfMAC}" ]; then
            echo "${vfIF}"
            break
        fi
    done
}

function calculate_packets_drop(){
    local nicName=$1
    local vfName=$(get_vf_name ${nicName})
    local synthDrop=0
    IFS=$'\n' read -r -d '' -a xdp_packet_array < <(ethtool -S $nicName | grep 'xdp' | cut -d':' -f2)
    for i in "${xdp_packet_array[@]}";
    do
        synthDrop=$((synthDrop+i))
    done
    vfDrop=$(ethtool -S $vfName | grep rx_xdp_drop | cut -d':' -f2)
    if [ $? -ne 0 ]; then
        echo "$((synthDrop))"
    else
        echo "$((vfDrop + synthDrop))"
    fi
}

function calculate_packets_forward(){
    local nicName=$1
    local vfName=$(get_vf_name ${nicName})
    vfForward=$(ethtool -S $vfName | grep rx_xdp_tx_xmit | cut -d':' -f2)
    echo "$((vfForward))"
}

function download_pktgen_scripts(){
    local ip=$1
    local dir=$2
    local type=$3
    # type indicates script type: multi threaded and single threaded, Fix: single threaded with constant PPS to send packets
    if [ "${type}" = "multi" ];then
        ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/pktgen_sample05_flow_per_thread.sh?h=v5.7.8 -O ${dir}/pktgen_sample.sh"
    elif [ "${type}" = "fix" ];then
        ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/pktgen_sample01_simple.sh?h=v5.7.8 -O ${dir}/pktgen_sample.sh"
        # insert fix rate packet transferring 50Kpps
        ssh $ip "sed -i '82i pg_set \$DEV \"ratep 50000\"' ${dir}/pktgen_sample.sh"
    else
        ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/pktgen_sample01_simple.sh?h=v5.7.8 -O ${dir}/pktgen_sample.sh"
    fi
    ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/functions.sh?h=v5.7.8 -O ${dir}/functions.sh"
    ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/parameters.sh?h=v5.7.8 -O ${dir}/parameters.sh"
    ssh $ip "chmod +x ${dir}/*.sh"
}

function start_pktgen(){
    local sender=$1
    local cores=$2
    local pktgenDir=$3
    local nicName=$4
    local forwarderSecondMAC=$5
    local forwarderSecondIP=$6
    local packetCount=$7
    if [ "${cores}" = "single" ];then
        startCommand="cd ${pktgenDir} && ./pktgen_sample.sh -i ${nicName} -m ${forwarderSecondMAC} -d ${forwarderSecondIP} -v -n${packetCount}"
        LogMsg "Starting pktgen on sender: $startCommand"
        ssh ${sender} "modprobe pktgen; lsmod | grep pktgen"
        result=$(ssh ${sender} "${startCommand}")
    else
        startCommand="cd ${pktgenDir} && ./pktgen_sample.sh -i ${nicName} -m ${forwarderSecondMAC} -d ${forwarderSecondIP} -v -n${packetCount} -t8"
        LogMsg "Starting pktgen on sender: ${startCommand}"
        ssh ${sender} "modprobe pktgen; lsmod | grep pktgen"
        result=$(ssh ${sender} "${startCommand}")
    fi
    pktgenResult=$result
    LogMsg "pktgen result: $pktgenResult"
}

function start_xdpdump(){
    local ip=$1
    local nicName=$2
    xdpdumpCommand="cd bpf-samples/xdpdump && ./xdpdump -i ${nicName} > ~/xdpdumpout_${ip}.txt"
    LogMsg "Starting xdpdump on ${ip} with command: ${xdpdumpCommand}"
    ssh -f ${ip} "sh -c '${xdpdumpCommand}'"
}