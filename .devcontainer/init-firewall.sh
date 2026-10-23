#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# --- Helper functions ---

add_cidrs() {
    local label="$1"
    # Reads CIDRs from stdin, validates, and adds to ipset
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERROR: Invalid CIDR range from $label: $cidr"
            exit 1
        fi
        echo "Adding $label range $cidr"
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done
}

# Resolves a host to its IPv4 addresses. DNS first, then /etc/hosts: names such
# as host.docker.internal live in /etc/hosts only and have no A record.
resolve_a() {
    local host="$1" ips
    ips=$(dig +noall +answer A "$host" | awk '$4 == "A" {print $5}') || true
    if [ -z "$ips" ]; then
        ips=$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u) || true
    fi
    [ -n "$ips" ] && printf '%s\n' "$ips"
}

# Adds one resolved address to the matching ipset: the port-less set when the
# config entry named no port, the host:port set when it named one.
add_allowed() {
    local ip="$1" port="${2:-}"
    if [ -n "$port" ]; then
        ipset add allowed-host-ports "$ip,tcp:$port" 2>/dev/null || true
    else
        ipset add allowed-domains "$ip" 2>/dev/null || true
    fi
}

# Splits a "host" or "host:port" config entry into $SPEC_HOST and $SPEC_PORT.
split_spec() {
    SPEC_HOST="${1%%:*}"
    SPEC_PORT="${1#"$SPEC_HOST"}"
    SPEC_PORT="${SPEC_PORT#:}"
}

fetch_json() {
    local url="$1"
    local label="$2"
    local result
    result=$(curl -s --connect-timeout 5 --max-time 20 "$url")
    if [ -z "$result" ]; then
        echo "ERROR: Failed to fetch $label from $url"
        exit 1
    fi
    echo "$result"
}

# --- Load the allow-list config (data, kept out of this script) ---
# Resolve alongside this script so both the baked /usr/local/bin copy and the
# bind-mounted .devcontainer copy find their sibling config.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/allowed-domains.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: allow-list config not found at $CONFIG_FILE"
    exit 1
fi

ALLOWED_DOMAINS=()          # every entry ("host" or "host:port") — resolved at boot
DYNAMIC_DOMAINS=()          # subset flagged "dynamic" — also refreshed every 10s
declare -A IS_DYNAMIC=()
while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"                              # strip comments
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue    # skip blank lines
    IFS=$' \t' read -r spec flag _ <<< "$line"
    split_spec "$spec"
    if [ -n "$SPEC_PORT" ] && [[ ! "$SPEC_PORT" =~ ^[0-9]{1,5}$ ]]; then
        echo "ERROR: Invalid port in allow-list entry: $spec"
        exit 1
    fi
    ALLOWED_DOMAINS+=("$spec")
    if [ "${flag:-}" = "dynamic" ]; then
        DYNAMIC_DOMAINS+=("$spec")
        IS_DYNAMIC["$spec"]=1
    fi
done < "$CONFIG_FILE"
echo "Loaded ${#ALLOWED_DOMAINS[@]} allowed hosts (${#DYNAMIC_DOMAINS[@]} dynamic) from $CONFIG_FILE"

# Inbound TCP ports, one per line, from a second config next to this script
PORTS_FILE="$SCRIPT_DIR/inbound-ports.conf"
if [ ! -f "$PORTS_FILE" ]; then
    echo "ERROR: inbound port config not found at $PORTS_FILE"
    exit 1
fi

INBOUND_PORTS=()
while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    IFS=$' \t' read -r port _ <<< "$line"
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "ERROR: Invalid port in inbound port config: $port"
        exit 1
    fi
    INBOUND_PORTS+=("$port")
done < "$PORTS_FILE"
echo "Loaded ${#INBOUND_PORTS[@]} inbound ports from $PORTS_FILE"

# --- Main script ---

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy allowed-host-ports 2>/dev/null || true

# Flushing clears the allow RULES but not the default POLICY, so a re-run against
# an already-configured firewall inherits the previous run's OUTPUT DROP. The
# GitHub/AWS bootstrap fetches below would then be dropped mid-script — bricking
# egress until a container restart. Reset to ACCEPT so a re-run rebuilds under
# the same open-then-clamp sequence as a fresh boot; the final rules below
# re-establish DROP + the allow-list.
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

# Stop a previously-spawned DNS refresher (if any). It would otherwise keep
# writing to a now-deleted ipset and accumulating errors in its log.
REFRESH_PID_FILE=/var/run/firewall-refresh.pid
if [ -f "$REFRESH_PID_FILE" ]; then
    old_pid=$(cat "$REFRESH_PID_FILE" 2>/dev/null || true)
    if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "Stopping previous DNS refresher (pid $old_pid)..."
        kill "$old_pid" 2>/dev/null || true
    fi
    rm -f "$REFRESH_PID_FILE"
fi

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Allow inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# Allow outbound SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Allow inbound SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support (maxelem increased for CloudFront ranges)
ipset create allowed-domains hash:net maxelem 65536
# A second set for allow-list entries that name a port: those open that port
# only, not the whole host.
ipset create allowed-host-ports hash:ip,port maxelem 65536

echo "Fetching GitHub IP ranges..."
gh_ranges=$(fetch_json "https://api.github.com/meta" "GitHub IP ranges")

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q | add_cidrs "GitHub"

echo "Fetching AWS IP ranges..."
aws_ranges=$(fetch_json "https://ip-ranges.amazonaws.com/ip-ranges.json" "AWS IP ranges")
aws_jq_query='.prefixes[] | select(.service == "S3" and .region == "eu-central-1") | .ip_prefix'

if ! echo "$aws_ranges" | jq -e $aws_jq_query >/dev/null; then
    echo "ERROR: AWS response missing required fields"
    exit 1
fi

echo "$aws_ranges" | jq -r $aws_jq_query | aggregate -q | add_cidrs "AWS S3"

# Resolve and add the allowed domains loaded from the config above
for spec in "${ALLOWED_DOMAINS[@]}"; do
    split_spec "$spec"
    echo "Resolving $SPEC_HOST..."
    ips=$(resolve_a "$SPEC_HOST")
    if [ -z "$ips" ]; then
        # Dynamic hosts have rotating IPs and may not resolve this instant; the
        # refresher will pick them up. A plain host failing to resolve is fatal.
        if [ -n "${IS_DYNAMIC[$spec]:-}" ]; then
            echo "WARN: could not resolve dynamic host $SPEC_HOST at boot (refresher will retry)"
            continue
        fi
        echo "ERROR: Failed to resolve $SPEC_HOST"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $SPEC_HOST: $ip"
            exit 1
        fi
        echo "Adding $ip${SPEC_PORT:+ port $SPEC_PORT} for $SPEC_HOST"
        add_allowed "$ip" "$SPEC_PORT"
    done < <(echo "$ips")
done

# Background refresher for the hosts flagged "dynamic" in the config (short DNS
# TTL / rotating IPs). The boot loop above resolves once; these publish A
# records with ~15s TTLs, so locked-in IPs go stale fast. This loop tops up the
# ipset every 10s. Entries are never removed — for a handful of domains the set
# converges to "every router IP we've ever seen" well within maxelem (65536).
refresh_dynamic_loop() {
    set +eo pipefail
    while true; do
        for spec in "${DYNAMIC_DOMAINS[@]}"; do
            split_spec "$spec"
            while read -r ip; do
                if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    add_allowed "$ip" "$SPEC_PORT"
                fi
            done < <(resolve_a "$SPEC_HOST" 2>/dev/null)
        done
        sleep 10
    done
}

refresh_dynamic_loop > /var/log/firewall-refresh.log 2>&1 < /dev/null &
REFRESH_PID=$!
disown "$REFRESH_PID"
echo "$REFRESH_PID" > "$REFRESH_PID_FILE"
echo "Started DNS refresher (pid $REFRESH_PID) for: ${DYNAMIC_DOMAINS[*]}"

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Allow traffic to Docker Compose internal networks (for DB and other services)
# Docker Compose typically uses 172.x.0.0/16 ranges for internal networks
for net in $(ip route | grep -oP '172\.\d+\.\d+\.\d+/\d+'); do
    echo "Allowing Docker internal network: $net"
    iptables -A INPUT -s "$net" -j ACCEPT
    iptables -A OUTPUT -d "$net" -j ACCEPT
done

# Allow inbound connections to published dev server ports from any source
# (needed because Docker Desktop's port forwarder may use a source IP outside 172.x)
for port in "${INBOUND_PORTS[@]}"; do
    echo "Allowing inbound port $port"
    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
done

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
# And to the host:port pairs, which open one port on one address
iptables -A OUTPUT -p tcp -m set --match-set allowed-host-ports dst,dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
