#!/bin/bash
SSH_OPTS="-o BatchMode=yes"
LARGE_MTU_SIZE=12000

if [ $# -ne 2 ]; then
    echo "Usage: $0 <servers-file> <clients-file>"
    echo "       This script runs the pre-flight checks for a Quobyte installation on server and clients hosts."
    echo "       It requires password-less ssh login and sudo on each host. nmap is required on all hosts."
    echo "       <servers-file> a list of hostnames or IP addresses, one per line"
    echo "       <clients-file> a list of hostnames or IP addresses, one per line"
    echo ""
    exit 1
fi

servers="$1"
clients="$2"

server_hosts=$(cat "$servers")
num_servers=$(wc -w <<< "$server_hosts")
client_hosts=$(cat "$clients")
num_clients=$(wc -w <<< "$client_hosts")

if [ $num_servers -lt 3 ]; then
    echo "You need at least three servers to install a Quobyte cluster. For full fault-tolerance"
    echo "a minimum of 4 servers is required."
    #exit 2
fi

if [ $num_clients -eq 0 ]; then
    echo "We recommend at least one client machine to test Quobyte properly."
    echo "You can use one of the server machines as a client."
    exit 3
fi


echo "1. Checking ssh access, sudo and nmap on each machine..."
errors=0
for h in $server_hosts $client_hosts; do
    ssh $SSH_OPTS $h 'command -v nmap &>/dev/null || exit 1; sudo -n true || exit 2; exit 0'
    rv=$?
    case $rv in
        255)
            echo "ERROR: cannot connect to $h via ssh"
            ((errors++))
            ;;
        1)
            echo "ERROR: nmap not installed on $h"
            ((errors++))
            ;;
        2)
            echo "ERROR: cannot sudo on host $h"
            ((errors++))
            ;;
    esac
done
if [ $errors -ne 0 ]; then
    exit 1
fi
echo "   DONE"
echo ""

echo "2. Checking chrony status on all server hosts..."
for h in $server_hosts; do
    ssh $SSH_OPTS $h "command -v chronyc &>/dev/null || exit 3; chronyc tracking | grep -q -E '^506.*' && exit 2; chronyc tracking | grep -q -E 'Reference ID\s*:\s*00000000' && exit 1; exit 0"
    rv=$?
    case $rv in
        1)
            echo "   !! chrony not synchronized on $h"
            ((errors++))
            ;;
        2)
            echo "   !! chrony not running on $h"
            ((errors++))
            ;;
        3)
            echo "   !! chrony not installed on $h"
            ((errors++))
            ;;
    esac
done
echo "   DONE"
echo ""

echo "3. Testing large pings (MTU check)..."
for h in $server_hosts $client_hosts; do
    peers=$(grep -vxF "$h" <<< "$server_hosts")
    ssh $SSH_OPTS $h 'for peer in '$peers'; do ping -n -c 3 -i 0.4 -W 0.5 -s '$LARGE_MTU_SIZE' $peer > /dev/null; if [ $? -ne 0 ]; then exit 1; fi; done'
    if [ $? -ne 0 ]; then
        echo "   !! failed to send large pings ($LARGE_MTU_SIZE bytes) from host $h"
        ((errors++))
    fi
done;
echo "   DONE"
echo ""

echo "4. Basic packet loss testing with flood pings..."
for h in $server_hosts $client_hosts; do
    peers=$(grep -vxF "$h" <<< "$server_hosts")
    ssh $SSH_OPTS $h 'for peer in '$peers'; do sudo ping -q -n -f -c 1000 -W 0.1 $peer | grep -q " 0% packet loss"; if [ $? -ne 0 ]; then exit 1; fi; done'
    if [ $? -ne 0 ]; then
        echo "   !! failed to send flood pings or packet loss occured on host $h"
        ((errors++))
    fi
done;
echo "   DONE"
echo ""

nmap_server=$(shuf -n 1 "$servers")
nmap_client=$(shuf -n 1 "$clients")

echo "5. Checking that all Quobyte ports are open with nmap from server $nmap_server..."
for h in $server_hosts; do
    ssh $SSH_OPTS $nmap_server "if ! sudo nmap -sn --send-ip -oG - $h | grep -q 'Status: Up'; then exit 1; fi; if sudo nmap --send-ip -sUT -p T:7871-7876,T:7861-7866,U:7861-7866,T:80,T:8080,T:7860 $h | grep -q -E ' (open[|])?filtered'; then exit 2; fi"
    rv=$?
    case $rv in
        1)
            echo "   !! host not reachable $h from server $nmap_server"
            ((errors++))
            ;;
        2)
            echo "   !! ports in status filtered on host $h"
            ((errors++))
            ;;
    esac
done
echo "   DONE"
echo ""

#also check the test server from one of the clients...
echo "6. Checking that all Quobyte ports are open with nmap from client $nmap_client..."
for h in $server_hosts; do
    ssh $SSH_OPTS $nmap_client "if ! sudo nmap -sn --send-ip -oG - $h | grep -q 'Status: Up'; then exit 1; fi; if sudo nmap --send-ip -sUT -p 7871-7876 $h | grep -q ' filtered'; then exit 2; fi"
    rv=$?
    case $rv in
        1)
            echo "   !! host is not reachable $h from client $nmap_client"
            ((errors++))
            ;;
        2)
            echo "   !! ports in status filtered on host $h"
            ((errors++))
            ;;
    esac
done
echo "   DONE"
echo ""

echo "7. Making sure the software repository can be reached..."
for h in $server_hosts $client_hosts; do
    ssh $SSH_OPTS $h 'HTTP_STATUS=$(curl -Is -o /dev/null -w "%{http_code}" --connect-timeout 5 https://packages.quobyte.com/repo/current 2>/dev/null); if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 400 ]; then exit 1; fi'
    if [ $? -ne 0 ]; then
        echo "   !! failed to contact repo via https on host $h"
        ((errors++))
    fi
done
echo "   DONE"
echo ""

echo "8. Checking QNS connectivity on server machines..."
qns_failure=0
for h in $server_hosts; do
    ssh $SSH_OPTS $h 'code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 https://gk6z7wszg1.execute-api.eu-central-1.amazonaws.com/v1); [ "$code" != "000" ] && [ "$code" -lt 500 ] || exit 1'
    if [ $? -ne 0 ]; then
        echo "   !! failed to contact QNS endpoint from host $h"
        ((errors++))
        qns_failure=1
    fi
done
echo "   DONE"
if [ "$qns_failure" -ne 0 ]; then
    echo "   WARNING: QNS not reachable from all server hosts. Please check connectivity or"
    echo "            follow instructions for an installation with custom DNS records."
fi
echo ""

echo "9. Checking the number of active ethernet connections on each server..."
more_than_one=0
for h in $server_hosts; do
    ssh $SSH_OPTS $h '[ $(ip -o link show up | grep -E "^[0-9]+: (eth|enp|ens|eno|ibp)" | grep -v "NO-CARRIER" | wc -l) -gt 1 ] && exit 1 || exit 0'
    if [ $? -ne 0 ]; then
        more_than_one=1
    fi
done
echo "   DONE"

if [ $more_than_one -ne 0 ]; then
    echo "   WARNING: At least one host has more than one active ethernet connection."
    echo "            Quobyte uses ALL available networks, which can lead to unexpected results"
    echo "            if the networks have different speeds."
    echo "            Please check the Quobyte documentation for the required configuration"
    echo "            and additional DNS records you might need:"
    echo "            https://support.quobyte.com/docs/16/latest/network_setup.html#network-setup"
fi
echo ""

echo "10. Checking if swap is enabled on any server..."
for h in $server_hosts; do
    ssh $SSH_OPTS $h '[ $(cat /proc/swaps | wc -l) -gt 1 ] && exit 1 || exit 0'
    if [ $? -ne 0 ]; then
        echo "   !! swap is enabled on $h, please disable permanently"
        ((errors++))
    fi
done
echo "   DONE"
echo ""

echo "11. Checking if SELinux or AppArmor is running on any server..."
for h in $server_hosts; do
    ssh $SSH_OPTS $h 'command -v sestatus >/dev/null 2>&1 && sestatus | grep -q -E "Current mode:\s*enforcing" && exit 1; [[ -f /sys/kernel/security/apparmor/profiles ]] && exit 2; exit 0'
    rv=$?
    case $rv in
        1)
            echo "   !! SELinux is in enforcing mode on server $h, please disable"
            ((errors++))
            ;;
        2)
            echo "   !! AppArmor is running on server $h, please disable"
            ((errors++))
            ;;
    esac
done
echo "   DONE"
echo ""

if [ $errors -ne 0 ]; then
    echo ""
    echo "WARNING: Some hosts had errors during the checks."
    echo "         Please check the affected hosts before you install Quobyte."
    exit 1
else
    echo ""
    echo "SUCCESS. All checks completed. You can continue with the Quobyte installer:"
    echo "wget https://www.quobyte.com/install;bash install"
fi
