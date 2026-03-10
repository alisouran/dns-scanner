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

# Cross-platform millisecond timestamp (macOS BSD date lacks %3N support)
# Detect the best available method once at startup to avoid per-call overhead
if perl -MTime::HiRes -e '' 2>/dev/null; then
    get_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
elif command -v python3 &>/dev/null; then
    get_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
else
    # Fallback: second-precision only (timestamps will be in seconds * 1000)
    get_ms() { echo $(( $(date +%s) * 1000 )); }
fi

# Cross-platform terminal lock: use flock on Linux, mkdir-based spinlock on macOS
if command -v flock &>/dev/null; then
    acquire_lock() { flock -x 9; }
    release_lock() { flock -u 9; }
    _HAVE_FLOCK=true
else
    acquire_lock() {
        while ! mkdir "$WORK_DIR/terminal.lockdir" 2>/dev/null; do sleep 0.01; done
    }
    release_lock() { rmdir "$WORK_DIR/terminal.lockdir" 2>/dev/null; }
    _HAVE_FLOCK=false
fi

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

print_clean_result() {
    local dns="$1"
    local latency_ms="$2"
    # Validate latency is numeric; default to 0 if not
    [[ "$latency_ms" =~ ^[0-9]+$ ]] || latency_ms=0

    # Color-code latency: green < 500ms, yellow 500-1500ms, red > 1500ms
    local latency_color
    if   [ "$latency_ms" -lt 500 ];  then latency_color="\033[32m"
    elif [ "$latency_ms" -lt 1500 ]; then latency_color="\033[33m"
    else                                   latency_color="\033[31m"
    fi

    # Acquire exclusive terminal lock
    acquire_lock
    # Clear the progress bar line, then print the clean result
    printf "\r\e[K \033[32m[ CLEAN ]\033[0m %s - ${latency_color}%dms\033[0m\n" \
        "\`$dns\`" "$latency_ms"
    # Write to output file while holding the lock (serialized with terminal writes)
    printf "%s %dms\n" "$dns" "$latency_ms" >> "$OUTPUT_FILE"
    release_lock
}

progress_updater() {
    local total="$1"
    local bar_width=20

    while true; do
        # Count completed workers from shared progress log (one line per done worker)
        local done_count=0
        [ -f "$WORK_DIR/progress.log" ] && done_count=$(wc -l < "$WORK_DIR/progress.log" | tr -d ' ')

        # Calculate fill ratio and percentage
        local filled=0 pct=0
        [ "$total" -gt 0 ] && filled=$(( (done_count * bar_width) / total ))
        [ "$total" -gt 0 ] && pct=$(( (done_count * 100) / total ))
        [ "$filled" -gt "$bar_width" ] && filled=$bar_width

        # Build bar string using pure bash (no external tools)
        local bar="" i=0
        while [ "$i" -lt "$filled" ];    do bar="${bar}#"; i=$(( i + 1 )); done
        while [ "$i" -lt "$bar_width" ]; do bar="${bar}-"; i=$(( i + 1 )); done

        # Acquire terminal lock, overwrite current line (no trailing newline)
        acquire_lock
        printf "\r\e[K[%s] %d%% (%d/%d) | Running..." \
            "$bar" "$pct" "$done_count" "$total"
        release_lock

        [ "$done_count" -ge "$total" ] && break
        sleep 0.4
    done
}

check_dns() {
    local dns="$1"
    local port="$2"
    local idx="$3"
    local dnstt_log="$WORK_DIR/dnstt_${idx}.log"
    local ssh_log="$WORK_DIR/ssh_${idx}.log"
    local result_file="$WORK_DIR/result_${idx}.txt"
    # Pre-declare ssh_pid so the EXIT trap doesn't reference an undefined variable
    local ssh_pid=""

    # 1. Start dnstt-client on this worker's unique port (port = BASE_PORT + idx, no conflicts)
    $DNSTT_BIN -udp "${dns}:53" -pubkey "$PUB_KEY" "$DNSTT_DOMAIN" \
        "127.0.0.1:${port}" > "$dnstt_log" 2>&1 &
    local dnstt_pid=$!

    # Subshell trap: kill child processes if this subshell is killed (e.g., Ctrl+C)
    trap 'kill -9 "$dnstt_pid" "$ssh_pid" 2>/dev/null' EXIT

    # 2. Quick-check: wait up to 1.5s for dnstt to start or crash early
    local tries=0
    while [ "$tries" -lt 3 ]; do
        sleep 0.5
        kill -0 "$dnstt_pid" 2>/dev/null || break
        tries=$((tries + 1))
    done

    # 3. Check if dnstt crashed during startup
    if ! kill -0 "$dnstt_pid" 2>/dev/null; then
        echo "${dns}|CRASH|0" > "$result_file"
        echo "." >> "$WORK_DIR/progress.log"
        return
    fi

    # 4. Capture start time immediately before SSH launch for precise latency
    local start_ms
    start_ms=$(get_ms)

    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -p "$port" "${SSH_USER}@127.0.0.1" > "$ssh_log" 2>&1 &
    ssh_pid=$!

    # 5. Poll SSH log for auth response, up to MAX_WAIT_TIME seconds.
    #    This approach works on all platforms (no GNU timeout dependency).
    local ssh_success=false
    local stream_created=false
    local elapsed=0
    while [ "$elapsed" -lt "$MAX_WAIT_TIME" ]; do
        # Success: SSH reached the server and got an auth response
        if grep -qE "Permission denied|publickey,password" "$ssh_log" 2>/dev/null; then
            ssh_success=true
            break
        fi
        # Track stream creation (used for DPI detection below)
        if grep -q "begin stream" "$dnstt_log" 2>/dev/null; then
            stream_created=true
        fi
        # Fail-fast: if SSH process died, stop waiting
        if ! kill -0 "$ssh_pid" 2>/dev/null; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # 6. Compute latency: time from SSH launch to auth response detection
    local end_ms latency_ms
    end_ms=$(get_ms)
    latency_ms=$(( end_ms - start_ms ))
    [ "$latency_ms" -lt 0 ] && latency_ms=0   # Guard against NTP clock skew

    # 7. Determine result based on SSH output and DNSTT stream state
    if [ "$ssh_success" = true ]; then
        echo "${dns}|CLEAN|${latency_ms}" > "$result_file"
        # Immediately print to terminal and append to output file (serialized via lock)
        print_clean_result "\`$dns\`" "$latency_ms"
    elif [ "$stream_created" = true ]; then
        # Stream was created but SSH failed -- DPI is interfering
        echo "${dns}|BLOCKED_BY_DPI|${latency_ms}" > "$result_file"
    else
        # No stream: DNS server is completely unreachable
        echo "${dns}|DEAD|0" > "$result_file"
    fi

    # 8. Remove the EXIT trap and cleanly kill worker processes
    trap - EXIT
    kill -9 "$dnstt_pid" "$ssh_pid" 2>/dev/null
    wait "$dnstt_pid" "$ssh_pid" 2>/dev/null

    # 9. Mark this worker as done (append to shared progress log for the live bar)
    echo "." >> "$WORK_DIR/progress.log"
}

# --- Main ---

if [ ! -f "$DNS_LIST_FILE" ]; then
    printf "Error: DNS list file '%s' not found.\n" "$DNS_LIST_FILE"
    exit 1
fi

# Collect raw entries (plain IPs or CIDR ranges) from the input file
RAW_ENTRIES=()
if [[ "$DNS_LIST_FILE" == *.csv ]]; then
    # CSV mode: extract first column (IP/CIDR), skip header row
    first_line=true
    while IFS=',' read -r ip _rest || [ -n "$ip" ]; do
        if $first_line; then
            first_line=false
            continue
        fi
        ip=$(echo "$ip" | tr -d ' \t"')
        [ -z "$ip" ] && continue
        RAW_ENTRIES+=("$ip")
    done < "$DNS_LIST_FILE"
else
    # TXT mode: one IP/CIDR per line, supports # comments
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line=$(echo "$line" | tr -d ' \t')
        [ -z "$line" ] && continue
        RAW_ENTRIES+=("$line")
    done < "$DNS_LIST_FILE"
fi

if [ "${#RAW_ENTRIES[@]}" -eq 0 ]; then
    printf "Error: No DNS entries found in '%s'.\n" "$DNS_LIST_FILE"
    exit 1
fi

# Expand any CIDR ranges into individual host IPs
# Process all entries in a single python3 call for speed (avoids one fork per line)
printf "Expanding %d entries (CIDR ranges -> individual IPs)...\n" "${#RAW_ENTRIES[@]}"

DNS_SERVERS=()
while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    DNS_SERVERS+=("$ip")
done < <(
    printf '%s\n' "${RAW_ENTRIES[@]}" | python3 -c "
import ipaddress, sys
for line in sys.stdin:
    entry = line.strip()
    if not entry:
        continue
    if '/' in entry:
        try:
            net = ipaddress.ip_network(entry, strict=False)
            if net.prefixlen == 32:
                print(net.network_address)
            else:
                for ip in net.hosts():
                    print(ip)
        except ValueError:
            pass
    else:
        print(entry)
"
)

if [ "${#DNS_SERVERS[@]}" -eq 0 ]; then
    printf "Error: No DNS servers produced after expanding '%s'.\n" "$DNS_LIST_FILE"
    exit 1
fi

# Safety prompt: confirm before launching massive scans
if [ "${#DNS_SERVERS[@]}" -gt 100000 ]; then
    printf "WARNING: %d IPs to scan. This will take a long time.\n" "${#DNS_SERVERS[@]}"
    printf "Continue? [y/N] "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        printf "Aborted.\n"
        exit 0
    fi
fi

# Setup
WORK_DIR=$(mktemp -d -t dnsscanner.XXXXXX)
# Open terminal lock fd 9 only when flock is available; mkdir-based lock doesn't need it
if [ "$_HAVE_FLOCK" = true ]; then
    exec 9>"$WORK_DIR/terminal.lock"
fi
trap cleanup EXIT INT TERM

printf "==================================================\n"
printf "  DNSTT Scanner (Parallel | Max %d workers)\n" "$MAX_PARALLEL"
printf "==================================================\n"
printf "  DNS list : %s (%d servers)\n" "$DNS_LIST_FILE" "${#DNS_SERVERS[@]}"
printf "  Output   : %s\n" "$OUTPUT_FILE"
printf "==================================================\n\n"

# Initialize output file and shared progress log before workers start
> "$OUTPUT_FILE"
> "$WORK_DIR/progress.log"
total=${#DNS_SERVERS[@]}

# Start live progress bar BEFORE dispatch so the user sees feedback immediately
progress_updater "$total" &
progress_pid=$!

# Dispatch workers in parallel (progress bar is already running in background)
idx=0
for dns in "${DNS_SERVERS[@]}"; do
    port=$((BASE_PORT + idx))
    wait_for_slot
    check_dns "$dns" "$port" "$idx" &
    idx=$((idx + 1))
done

# Wait for all workers to finish
wait

# Stop the progress updater and clear the progress bar line
kill "$progress_pid" 2>/dev/null
wait "$progress_pid" 2>/dev/null
printf "\r\e[K"

# Sort output file by latency ascending (field 2: "IP Xms", sort -n ignores "ms" suffix)
if [ -f "$OUTPUT_FILE" ]; then
    sort -t' ' -k2 -n -o "$OUTPUT_FILE" "$OUTPUT_FILE"
fi

# Count clean results from the output file
clean_count=0
[ -f "$OUTPUT_FILE" ] && clean_count=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')

printf "\n==================================================\n"
printf "  Done! %d/%d servers are clean.\n" "$clean_count" "$total"
if [ "$clean_count" -gt 0 ]; then
    printf "  Working DNS saved to: %s\n" "$OUTPUT_FILE"
fi
printf "==================================================\n"