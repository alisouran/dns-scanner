#!/bin/bash

# --- Load Configuration from .env ---
ENV_FILE="$(cd "$(dirname "$0")" && pwd)/.env"
if [ ! -f "$ENV_FILE" ]; then
    printf "Error: .env file not found at '%s'.\n" "$ENV_FILE"
    printf "Create one based on .env.example\n"
    exit 1
fi
source "$ENV_FILE"

# Validate required variables
for var in PUB_KEY DNSTT_DOMAIN SSH_USER DNSTT_BIN DNS_LIST_FILE; do
    if [ -z "${!var}" ]; then
        printf "Error: %s is not set in .env\n" "$var"
        exit 1
    fi
done

# Defaults for optional variables
MAX_WAIT_TIME="${MAX_WAIT_TIME:-45}"
SCAN_TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
OUTPUT_FILE="${OUTPUT_FILE:-working-dns_${SCAN_TIMESTAMP}.txt}"
BASE_PORT="${BASE_PORT:-10000}"
MAX_PARALLEL="${MAX_PARALLEL:-5}"

# --- Functions ---

cleanup() {
    # Terminate all child processes of the current shell group
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}

wait_for_slot() {
    while true; do
        local current_jobs
        current_jobs=$(jobs -rp | wc -l | tr -d ' ')
        if [ "$current_jobs" -lt "$MAX_PARALLEL" ]; then
            break
        fi
        sleep 0.5
    done
}

check_dns() {
    local dns="$1"
    local port="$2"
    local idx="$3"
    local dnstt_log="$WORK_DIR/dnstt_${idx}.log"
    local ssh_log="$WORK_DIR/ssh_${idx}.log"
    local result_file="$WORK_DIR/result_${idx}.txt"

    # 1. Kill any process holding this port
    local pids
    pids=$(lsof -ti tcp:"$port" 2>/dev/null)
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi
    
    # Crucial for macOS: give the OS enough time to release the port state (TIME_WAIT)
    sleep 2

    # 2. Start dnstt-client on this worker's unique port
    $DNSTT_BIN -udp "${dns}:53" -pubkey "$PUB_KEY" "$DNSTT_DOMAIN" \
        "127.0.0.1:${port}" > "$dnstt_log" 2>&1 &
    local dnstt_pid=$!

    # Subshell trap: ensure these specific child processes die if the subshell is killed (e.g., Ctrl+C)
    trap 'kill -9 "$dnstt_pid" "$ssh_pid" 2>/dev/null' EXIT

    sleep 3

    # 3. Check if dnstt crashed immediately
    if ! kill -0 "$dnstt_pid" 2>/dev/null; then
        echo "${dns}|CRASH" > "$result_file"
        return
    fi

    # 4. Start SSH to trigger the stream
    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -p "$port" "${SSH_USER}@127.0.0.1" > "$ssh_log" 2>&1 &
    local ssh_pid=$!

    # 5. Monitor for success
    local ssh_success=false
    local stream_created=false
    local i=1
    
    while [ "$i" -le "$MAX_WAIT_TIME" ]; do
        # Success check
        if grep -Eq "Permission denied|publickey,password" "$ssh_log" 2>/dev/null; then
            ssh_success=true
            break
        fi
        
        # Monitor stream creation
        if grep -q "begin stream" "$dnstt_log" 2>/dev/null; then
            stream_created=true
        fi
        
        # Fail-Fast mechanism: If SSH process dies abruptly, stop waiting!
        if ! kill -0 "$ssh_pid" 2>/dev/null; then
            break
        fi

        sleep 1
        i=$((i + 1))
    done

    # 6. Write result
    if [ "$ssh_success" = true ]; then
        echo "${dns}|CLEAN" > "$result_file"
    elif [ "$stream_created" = true ]; then
        echo "${dns}|BLOCKED_BY_DPI" > "$result_file"
    else
        echo "${dns}|DEAD" > "$result_file"
    fi

    # 7. Cleanup worker processes cleanly before exiting the function
    trap - EXIT # Remove the trap since we are cleaning up normally
    kill -9 "$dnstt_pid" "$ssh_pid" 2>/dev/null
    wait "$dnstt_pid" "$ssh_pid" 2>/dev/null
}

# --- Main ---

if [ ! -f "$DNS_LIST_FILE" ]; then
    printf "Error: DNS list file '%s' not found.\n" "$DNS_LIST_FILE"
    exit 1
fi

DNS_SERVERS=()
if [[ "$DNS_LIST_FILE" == *.csv ]]; then
    # CSV mode: extract first column (IP), skip header row
    first_line=true
    while IFS=',' read -r ip _rest || [ -n "$ip" ]; do
        if $first_line; then
            first_line=false
            continue
        fi
        ip=$(echo "$ip" | tr -d ' \t"')
        [ -z "$ip" ] && continue
        DNS_SERVERS+=("$ip")
    done < "$DNS_LIST_FILE"
else
    # TXT mode: one IP per line, supports # comments
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line=$(echo "$line" | tr -d ' \t')
        [ -z "$line" ] && continue
        DNS_SERVERS+=("$line")
    done < "$DNS_LIST_FILE"
fi

if [ "${#DNS_SERVERS[@]}" -eq 0 ]; then
    printf "Error: No DNS servers found in '%s'.\n" "$DNS_LIST_FILE"
    exit 1
fi

# Setup
WORK_DIR=$(mktemp -d -t dnsscanner.XXXXXX)
trap cleanup EXIT INT TERM

printf "==================================================\n"
printf "  DNSTT Scanner (Parallel | Max %d workers)\n" "$MAX_PARALLEL"
printf "==================================================\n"
printf "  DNS list : %s (%d servers)\n" "$DNS_LIST_FILE" "${#DNS_SERVERS[@]}"
printf "  Output   : %s\n" "$OUTPUT_FILE"
printf "==================================================\n\n"

# Dispatch workers in parallel
idx=0
for dns in "${DNS_SERVERS[@]}"; do
    port=$((BASE_PORT + idx))
    printf "[*] Launching check for %s (port %d)\n" "$dns" "$port"
    wait_for_slot
    check_dns "$dns" "$port" "$idx" &
    idx=$((idx + 1))
done

printf "\n[~] Waiting for all checks to finish...\n"
wait

# Collect results
printf "\n==================================================\n"
printf "                   SCAN RESULTS\n"
printf "==================================================\n"

> "$OUTPUT_FILE"
clean_count=0
total=${#DNS_SERVERS[@]}

idx=0
while [ "$idx" -lt "$total" ]; do
    result_file="$WORK_DIR/result_${idx}.txt"
    if [ -f "$result_file" ]; then
        IFS='|' read -r dns status < "$result_file"
        case "$status" in
            CLEAN)
                printf " \033[32m[ CLEAN ]\033[0m %s\n" "$dns"
                echo "$dns" >> "$OUTPUT_FILE"
                clean_count=$((clean_count + 1))
                ;;
            BLOCKED_BY_DPI)
                printf " \033[33m[ BLOCKED BY DPI ]\033[0m %s\n" "$dns"
                ;;
            DEAD)
                printf " \033[31m[ DEAD ]\033[0m %s\n" "$dns"
                ;;
            CRASH)
                printf " \033[31m[ CRASH ]\033[0m %s\n" "$dns"
                ;;
        esac
    else
        printf " \033[31m[ ERROR ]\033[0m DNS #%d - no result\n" "$idx"
    fi
    idx=$((idx + 1))
done

printf "\n==================================================\n"
printf "  Done! %d/%d servers are clean.\n" "$clean_count" "$total"
if [ "$clean_count" -gt 0 ]; then
    printf "  Working DNS saved to: %s\n" "$OUTPUT_FILE"
fi
printf "==================================================\n"