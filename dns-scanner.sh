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
STREAM_TIMEOUT="${STREAM_TIMEOUT:-8}"    # Max seconds to wait for dnstt stream creation
AUTH_TIMEOUT="${AUTH_TIMEOUT:-20}"        # Max seconds after stream for SSH auth response
PREFILTER="${PREFILTER:-true}"           # Pre-filter IPs by checking port 53 responsiveness
PREFILTER_TIMEOUT="${PREFILTER_TIMEOUT:-2}" # Seconds to wait for DNS response in pre-filter
SCAN_MODE="${SCAN_MODE:-udp}"            # Scan mode: udp, dot (DNS-over-TLS:853), or both
RESUME_FILE="${RESUME_FILE:-}"           # Path to previous scan progress file to resume from
SCAN_TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
RESULT_DIR="dns-result"
mkdir -p "$RESULT_DIR"
DEAD_CACHE="${DEAD_CACHE:-${RESULT_DIR}/dead_cache.txt}"
DEAD_CACHE_MAX_AGE="${DEAD_CACHE_MAX_AGE:-86400}"
PROGRESS_FILE="${RESULT_DIR}/scan_progress_${SCAN_TIMESTAMP}.dat"
OUTPUT_FILE="${OUTPUT_FILE:-${RESULT_DIR}/working-dns_${SCAN_TIMESTAMP}.txt}"
BASE_PORT="${BASE_PORT:-10000}"
MAX_PARALLEL="${MAX_PARALLEL:-5}"

# --- Functions ---

_SHUTTING_DOWN=false

cleanup() {
    # Prevent re-entry from cascading signals (INT -> cleanup -> exit -> EXIT -> cleanup)
    $_SHUTTING_DOWN && return
    _SHUTTING_DOWN=true

    printf "\n\033[33mInterrupted. Shutting down...\033[0m\n" >&2

    # Kill progress updater first
    [ -n "$progress_pid" ] && kill "$progress_pid" 2>/dev/null

    # Send TERM to all child processes (workers will run their EXIT traps to kill dnstt/ssh)
    pkill -TERM -P $$ 2>/dev/null
    sleep 0.5
    # Force-kill any stragglers that didn't exit gracefully
    pkill -KILL -P $$ 2>/dev/null

    # Reap all zombie/dead children
    wait 2>/dev/null

    # Now safe to remove temp directory (all children are dead)
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    [ -n "$IP_FILE" ] && rm -f "$IP_FILE" "${IP_FILE}.alive"
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
    local proto="${3:-udp}"
    # Validate latency is numeric; default to 0 if not
    [[ "$latency_ms" =~ ^[0-9]+$ ]] || latency_ms=0

    # Color-code latency: green < 500ms, yellow 500-1500ms, red > 1500ms
    local latency_color
    if   [ "$latency_ms" -lt 500 ];  then latency_color="\033[32m"
    elif [ "$latency_ms" -lt 1500 ]; then latency_color="\033[33m"
    else                                   latency_color="\033[31m"
    fi

    # Protocol badge
    local proto_label
    proto_label=$(echo "$proto" | tr '[:lower:]' '[:upper:]')

    # Acquire exclusive terminal lock
    acquire_lock
    # Clear the progress bar line, then print the clean result
    printf "\r\e[K \033[32m[ CLEAN ]\033[0m %s - ${latency_color}%dms\033[0m [%s]\n" \
        "$dns" "$latency_ms" "$proto_label"
    # Write to output file while holding the lock (serialized with terminal writes)
    printf "%s %dms %s\n" "$dns" "$latency_ms" "$proto_label" >> "$OUTPUT_FILE"
    release_lock
}

progress_updater() {
    local total="$1"
    local bar_width=20

    # Trap TERM and INT signals to exit gracefully
    trap 'break' TERM INT

    while true; do
        # Exit if WORK_DIR was removed (cleanup was called)
        [ ! -d "$WORK_DIR" ] && break

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
    local proto="${4:-udp}"
    local dnstt_log="$WORK_DIR/dnstt_${idx}.log"
    local ssh_log="$WORK_DIR/ssh_${idx}.log"
    local result_file="$WORK_DIR/result_${idx}.txt"
    # Pre-declare ssh_pid so the EXIT trap doesn't reference an undefined variable
    local ssh_pid=""

    # Bail out immediately if WORK_DIR was removed (shutdown in progress)
    [ ! -d "$WORK_DIR" ] && return

    # Skip if this subnet has 15+ failures and 0 hits (subnet blacklist)
    local _subnet="${dns%.*}"
    local _fail_file="$WORK_DIR/subnet_fails/${_subnet}.count"
    if [ -f "$_fail_file" ]; then
        local _fails
        _fails=$(wc -l < "$_fail_file" 2>/dev/null | tr -d ' ')
        if [ "$_fails" -ge 15 ] && [ ! -f "$WORK_DIR/subnet_hits/${_subnet}" ]; then
            [ -d "$WORK_DIR" ] && echo "." >> "$WORK_DIR/progress.log"
            return
        fi
    fi

    # 1. Start dnstt-client on this worker's unique port (protocol-aware)
    case "$proto" in
        udp)
            $DNSTT_BIN -udp "${dns}:53" -pubkey "$PUB_KEY" "$DNSTT_DOMAIN" \
                "127.0.0.1:${port}" > "$dnstt_log" 2>&1 &
            ;;
        dot)
            $DNSTT_BIN -dot "${dns}:853" -pubkey "$PUB_KEY" "$DNSTT_DOMAIN" \
                "127.0.0.1:${port}" > "$dnstt_log" 2>&1 &
            ;;
    esac
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
        if [ -d "$WORK_DIR" ]; then
            echo "${dns}|CRASH|0|${proto}" > "$result_file"
            printf "%s|CRASH|0|%s|%s\n" "$dns" "$proto" "$(date +%s)" \
                >> "$PROGRESS_FILE" 2>/dev/null
            echo "." >> "$WORK_DIR/progress.log"
        fi
        return
    fi

    # 4. Capture start time immediately before SSH launch for precise latency
    local start_ms
    start_ms=$(get_ms)

    ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -p "$port" "${SSH_USER}@127.0.0.1" > "$ssh_log" 2>&1 &
    ssh_pid=$!

    # 5. Two-phase adaptive timeout for faster scanning.
    #    Phase 1: Wait for dnstt stream creation (STREAM_TIMEOUT seconds).
    #    Phase 2: If stream created, wait for SSH auth response (AUTH_TIMEOUT seconds).
    local ssh_success=false
    local stream_created=false

    # Phase 1: Wait for stream creation
    local elapsed=0
    while [ "$elapsed" -lt "$STREAM_TIMEOUT" ]; do
        # Check for early SSH success (fast servers may respond before stream detection)
        if grep -qE "Permission denied|publickey,password" "$ssh_log" 2>/dev/null; then
            ssh_success=true
            break
        fi
        if grep -q "begin stream" "$dnstt_log" 2>/dev/null; then
            stream_created=true
            break
        fi
        # Fail-fast: both processes died
        if ! kill -0 "$dnstt_pid" 2>/dev/null && ! kill -0 "$ssh_pid" 2>/dev/null; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # Phase 2: Stream created — wait for SSH auth (shorter deadline)
    if [ "$stream_created" = true ] && [ "$ssh_success" != true ]; then
        local auth_elapsed=0
        while [ "$auth_elapsed" -lt "$AUTH_TIMEOUT" ]; do
            if grep -qE "Permission denied|publickey,password" "$ssh_log" 2>/dev/null; then
                ssh_success=true
                break
            fi
            if ! kill -0 "$ssh_pid" 2>/dev/null; then
                break
            fi
            sleep 1
            auth_elapsed=$((auth_elapsed + 1))
        done
    fi

    # 6. Compute latency: time from SSH launch to auth response detection
    local end_ms latency_ms
    end_ms=$(get_ms)
    latency_ms=$(( end_ms - start_ms ))
    [ "$latency_ms" -lt 0 ] && latency_ms=0   # Guard against NTP clock skew

    # 7. Determine result based on SSH output and DNSTT stream state
    local status="DEAD"
    if [ -d "$WORK_DIR" ]; then
        if [ "$ssh_success" = true ]; then
            status="CLEAN"
            echo "${dns}|CLEAN|${latency_ms}|${proto}" > "$result_file"
            # Immediately print to terminal and append to output file (serialized via lock)
            print_clean_result "$dns" "$latency_ms" "$proto"

            # Subnet expansion: queue more IPs from this /24 on first hit
            local subnet
            subnet="${dns%.*}"
            local hit_marker="$WORK_DIR/subnet_hits/${subnet}"
            mkdir -p "$WORK_DIR/subnet_hits" 2>/dev/null
            if [ ! -f "$hit_marker" ]; then
                touch "$hit_marker"
                # Generate 50 random IPs from same /24 and queue them
                python3 -c "
import random; subnet='${subnet}'
ips=[f'{subnet}.{i}' for i in range(1,255)]
random.shuffle(ips)
for ip in ips[:50]: print(ip)
" >> "$WORK_DIR/dynamic_queue.txt" 2>/dev/null
            fi
        elif [ "$stream_created" = true ]; then
            status="BLOCKED_BY_DPI"
            # Stream was created but SSH failed -- DPI is interfering
            echo "${dns}|BLOCKED_BY_DPI|${latency_ms}|${proto}" > "$result_file"
        else
            # No stream: DNS server is completely unreachable
            echo "${dns}|DEAD|0|${proto}" > "$result_file"
        fi

        # Track subnet failures for skip logic
        if [ "$status" != "CLEAN" ]; then
            local subnet="${dns%.*}"
            mkdir -p "$WORK_DIR/subnet_fails" 2>/dev/null
            echo "1" >> "$WORK_DIR/subnet_fails/${subnet}.count" 2>/dev/null
        fi
    fi

    # 8. Write result to persistent progress file (survives Ctrl+C for resume)
    if [ -d "$WORK_DIR" ]; then
        printf "%s|%s|%s|%s|%s\n" "$dns" "$status" "$latency_ms" "$proto" "$(date +%s)" \
            >> "$PROGRESS_FILE" 2>/dev/null
    fi

    # 9. Remove the EXIT trap and cleanly kill worker processes
    trap - EXIT
    kill -9 "$dnstt_pid" "$ssh_pid" 2>/dev/null
    wait "$dnstt_pid" "$ssh_pid" 2>/dev/null

    # 10. Mark this worker as done (append to shared progress log for the live bar)
    [ -d "$WORK_DIR" ] && echo "." >> "$WORK_DIR/progress.log"
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

# Expand any CIDR ranges into individual host IPs (all hosts — pre-filter handles reduction)
# Use a temp file instead of bash array to handle 500K+ IPs efficiently
IP_FILE=$(mktemp)
printf "Expanding %d entries (CIDR ranges -> individual IPs)...\n" "${#RAW_ENTRIES[@]}"

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
" > "$IP_FILE"

ip_count=$(wc -l < "$IP_FILE" | tr -d ' ')
if [ "$ip_count" -eq 0 ]; then
    printf "Error: No DNS servers produced after expanding '%s'.\n" "$DNS_LIST_FILE"
    rm -f "$IP_FILE"
    exit 1
fi
printf "Expanded to %d IPs.\n" "$ip_count"

# --- Resume: skip already-tested IPs from a previous scan ---
if [ -n "$RESUME_FILE" ] && [ -f "$RESUME_FILE" ]; then
    printf "Resuming from %s...\n" "$RESUME_FILE"
    resume_before=$ip_count
    # Build list of already-tested IPs and recover CLEAN results
    _resume_tested=$(mktemp)
    _resume_clean=0
    while IFS='|' read -r r_ip r_status r_latency r_proto r_ts; do
        [ -z "$r_ip" ] && continue
        echo "$r_ip" >> "$_resume_tested"
        if [ "$r_status" = "CLEAN" ]; then
            proto_label=$(echo "${r_proto:-udp}" | tr '[:lower:]' '[:upper:]')
            printf "%s %dms %s\n" "$r_ip" "$r_latency" "$proto_label" >> "$OUTPUT_FILE"
            _resume_clean=$((_resume_clean + 1))
        fi
    done < "$RESUME_FILE"
    sort -u -o "$_resume_tested" "$_resume_tested"

    # Filter out already-tested IPs using sort + comm (fast set difference)
    sort -o "$IP_FILE" "$IP_FILE"
    comm -23 "$IP_FILE" "$_resume_tested" > "${IP_FILE}.tmp"
    mv "${IP_FILE}.tmp" "$IP_FILE"
    rm -f "$_resume_tested"
    ip_count=$(wc -l < "$IP_FILE" | tr -d ' ')
    resume_skipped=$((resume_before - ip_count))
    printf "Resume: %d already tested (%d CLEAN recovered), %d remaining\n" \
        "$resume_skipped" "$_resume_clean" "$ip_count"
fi

# --- Dead Cache: skip IPs known to be dead from recent scans ---
if [ -f "$DEAD_CACHE" ]; then
    dead_before=$ip_count
    _dead_valid=$(mktemp)
    now_epoch=$(date +%s)
    while IFS='|' read -r d_ip d_ts; do
        [ -z "$d_ip" ] && continue
        age=$(( now_epoch - d_ts ))
        if [ "$age" -lt "$DEAD_CACHE_MAX_AGE" ]; then
            echo "$d_ip" >> "$_dead_valid"
        fi
    done < "$DEAD_CACHE"

    if [ -s "$_dead_valid" ]; then
        sort -u -o "$_dead_valid" "$_dead_valid"
        sort -o "$IP_FILE" "$IP_FILE"
        comm -23 "$IP_FILE" "$_dead_valid" > "${IP_FILE}.tmp"
        mv "${IP_FILE}.tmp" "$IP_FILE"
        ip_count=$(wc -l < "$IP_FILE" | tr -d ' ')
        dead_skipped=$((dead_before - ip_count))
        [ "$dead_skipped" -gt 0 ] && \
            printf "Dead cache: skipped %d IPs known dead within last %ds\n" \
                "$dead_skipped" "$DEAD_CACHE_MAX_AGE"
    fi
    rm -f "$_dead_valid"
fi

# --- Pre-filter: quickly eliminate IPs that don't respond ---
# For "dot" mode, skip UDP pre-filter (port 853 check is done via TCP below)
# For "udp" or "both" mode, run UDP pre-filter on port 53
if [ "$PREFILTER" = "true" ] && [ "$SCAN_MODE" != "dot" ]; then
    pre_total=$ip_count
    printf "Pre-filtering %d IPs (UDP port 53 probe, %ss timeout)...\n" "$pre_total" "$PREFILTER_TIMEOUT"

    python3 -c "
import socket, select, struct, sys, time

def build_dns_query(domain='google.com'):
    header = struct.pack('>HHHHHH', 0x1234, 0x0100, 1, 0, 0, 0)
    qname = b''
    for part in domain.split('.'):
        qname += bytes([len(part)]) + part.encode()
    qname += b'\x00'
    return header + qname + struct.pack('>HH', 1, 1)

timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
query = build_dns_query()

with open(sys.argv[1]) as f:
    ips = [line.strip() for line in f if line.strip()]

alive = set()

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setblocking(False)
try:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 2 * 1024 * 1024)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2 * 1024 * 1024)
except Exception:
    pass

def drain_responses():
    while True:
        ready, _, _ = select.select([sock], [], [], 0)
        if not ready:
            break
        try:
            data, addr = sock.recvfrom(512)
            alive.add(addr[0])
        except Exception:
            break

# Send in batches of 300 with small delays to avoid overwhelming the socket buffer
BATCH_SIZE = 300
sent = 0
total = len(ips)
for i in range(0, total, BATCH_SIZE):
    batch = ips[i:i+BATCH_SIZE]
    for ip in batch:
        try:
            sock.sendto(query, (ip, 53))
        except Exception:
            pass
    sent += len(batch)
    drain_responses()
    # Progress feedback every 10K IPs
    if sent % 10000 < BATCH_SIZE:
        sys.stderr.write(f'\r  Sent {sent}/{total} probes, {len(alive)} responses so far...')
        sys.stderr.flush()
    time.sleep(0.05)

sys.stderr.write(f'\r  Sent {total}/{total} probes, waiting for responses...          \n')
sys.stderr.flush()

# Second pass: re-send to IPs that haven't responded yet (packet loss recovery)
not_seen = [ip for ip in ips if ip not in alive]
for i in range(0, len(not_seen), BATCH_SIZE):
    batch = not_seen[i:i+BATCH_SIZE]
    for ip in batch:
        try:
            sock.sendto(query, (ip, 53))
        except Exception:
            pass
    drain_responses()
    time.sleep(0.05)

# Collect remaining responses until timeout
deadline = time.time() + timeout
while time.time() < deadline:
    remaining = deadline - time.time()
    if remaining <= 0:
        break
    ready, _, _ = select.select([sock], [], [], min(remaining, 0.05))
    if ready:
        try:
            data, addr = sock.recvfrom(512)
            alive.add(addr[0])
        except Exception:
            pass

sock.close()

# Write alive IPs to output file
out_path = sys.argv[1] + '.alive'
with open(out_path, 'w') as f:
    for ip in alive:
        f.write(ip + '\n')
" "$IP_FILE" "$PREFILTER_TIMEOUT"

    if [ -f "${IP_FILE}.alive" ]; then
        pre_alive=$(wc -l < "${IP_FILE}.alive" | tr -d ' ')
    else
        pre_alive=0
    fi
    pre_filtered=$((pre_total - pre_alive))
    printf "Pre-filter: %d/%d IPs respond on port 53 (%d filtered out, %.0f%% reduction)\n" \
        "$pre_alive" "$pre_total" "$pre_filtered" \
        "$(python3 -c "print(${pre_filtered}/${pre_total}*100 if ${pre_total}>0 else 0)")"

    if [ "$pre_alive" -eq 0 ]; then
        printf "Warning: No IPs responded to DNS pre-filter. Running full scan instead.\n"
    else
        mv "${IP_FILE}.alive" "$IP_FILE"
        ip_count=$pre_alive
    fi
    rm -f "${IP_FILE}.alive"
fi

# Setup
WORK_DIR=$(mktemp -d -t dnsscanner.XXXXXX)
# Open terminal lock fd 9 only when flock is available; mkdir-based lock doesn't need it
if [ "$_HAVE_FLOCK" = true ]; then
    exec 9>"$WORK_DIR/terminal.lock"
fi
# On INT/TERM: clean up AND exit immediately (prevents the for loop from continuing)
trap 'cleanup; exit 130' INT TERM
# On normal EXIT: just clean up temp files
trap cleanup EXIT

scan_mode_label=$(echo "$SCAN_MODE" | tr '[:lower:]' '[:upper:]')
printf "==================================================\n"
printf "  DNSTT Scanner (Parallel | Max %d workers)\n" "$MAX_PARALLEL"
printf "==================================================\n"
printf "  DNS list : %s (%d servers)\n" "$DNS_LIST_FILE" "$ip_count"
printf "  Mode     : %s\n" "$scan_mode_label"
printf "  Timeouts : stream=%ds, auth=%ds\n" "$STREAM_TIMEOUT" "$AUTH_TIMEOUT"
printf "  Output   : %s\n" "$OUTPUT_FILE"
printf "==================================================\n\n"

# Initialize output file and shared progress log before workers start
> "$OUTPUT_FILE"
> "$WORK_DIR/progress.log"

# Calculate total work items (in "both" mode, each IP is tested twice)
if [ "$SCAN_MODE" = "both" ]; then
    total=$(( ip_count * 2 ))
else
    total=$ip_count
fi

# Start live progress bar BEFORE dispatch so the user sees feedback immediately
progress_updater "$total" &
progress_pid=$!

# Initialize dynamic queue and subnet tracking
> "$WORK_DIR/dynamic_queue.txt"
mkdir -p "$WORK_DIR/subnet_hits" "$WORK_DIR/subnet_fails"

# Helper: dispatch a single DNS check with the configured scan mode
dispatch_dns() {
    local dns="$1"
    if [ "$SCAN_MODE" = "both" ]; then
        port=$((BASE_PORT + idx))
        wait_for_slot
        check_dns "$dns" "$port" "$idx" "udp" &
        idx=$((idx + 1))
        port=$((BASE_PORT + idx))
        wait_for_slot
        check_dns "$dns" "$port" "$idx" "dot" &
        idx=$((idx + 1))
    else
        port=$((BASE_PORT + idx))
        wait_for_slot
        check_dns "$dns" "$port" "$idx" "$SCAN_MODE" &
        idx=$((idx + 1))
    fi
}

# Dispatch initial batch of workers (read from file, not bash array)
idx=0
while IFS= read -r dns; do
    [ -z "$dns" ] && continue
    dispatch_dns "$dns"
done < "$IP_FILE"

# Dynamic queue consumer: process IPs added by subnet expansion
# Check every 2 seconds for new IPs until all workers are done
while true; do
    # Process any dynamically queued IPs from subnet expansion
    if [ -s "$WORK_DIR/dynamic_queue.txt" ] 2>/dev/null; then
        # Atomically swap the queue file to avoid races with workers
        mv "$WORK_DIR/dynamic_queue.txt" "$WORK_DIR/dynamic_processing.txt" 2>/dev/null
        > "$WORK_DIR/dynamic_queue.txt"

        if [ -f "$WORK_DIR/dynamic_processing.txt" ]; then
            while IFS= read -r dns; do
                [ -z "$dns" ] && continue
                dispatch_dns "$dns"
                # Update total for progress bar
                total=$((total + 1))
                [ "$SCAN_MODE" = "both" ] && total=$((total + 1))
            done < "$WORK_DIR/dynamic_processing.txt"
            rm -f "$WORK_DIR/dynamic_processing.txt"
        fi
    fi

    # Check if all workers are done
    running=$(jobs -rp | wc -l | tr -d ' ')
    # Subtract 1 for the progress_updater background job
    running=$((running - 1))
    [ "$running" -lt 0 ] && running=0

    if [ "$running" -eq 0 ]; then
        # Double-check: no more dynamic queue items
        if [ ! -s "$WORK_DIR/dynamic_queue.txt" ] 2>/dev/null; then
            break
        fi
    fi
    sleep 2
done

# Final wait for any remaining workers
wait

# Stop the progress updater and clear the progress bar line
kill "$progress_pid" 2>/dev/null
wait "$progress_pid" 2>/dev/null
printf "\r\e[K"

# --- Save dead IPs to cache for future scans ---
if [ -f "$PROGRESS_FILE" ]; then
    now_epoch=$(date +%s)
    while IFS='|' read -r d_ip d_status d_lat d_proto d_ts; do
        if [ "$d_status" = "DEAD" ] || [ "$d_status" = "CRASH" ]; then
            printf "%s|%s\n" "$d_ip" "$now_epoch" >> "$DEAD_CACHE"
        fi
    done < "$PROGRESS_FILE"
    # Deduplicate dead cache (keep latest timestamp per IP)
    if [ -f "$DEAD_CACHE" ]; then
        awk -F'|' '{data[$1]=$0} END {for(k in data) print data[k]}' "$DEAD_CACHE" \
            > "${DEAD_CACHE}.tmp" && mv "${DEAD_CACHE}.tmp" "$DEAD_CACHE"
    fi
fi

# Sort output file by latency ascending and remove duplicate DNS entries (keep last/highest ping)
if [ -f "$OUTPUT_FILE" ]; then
    sort -t' ' -k2 -n -o "$OUTPUT_FILE" "$OUTPUT_FILE"
    # Deduplicate: awk overwrites each DNS with its last (highest latency) line, then re-sort
    awk '{data[$1]=$0} END {for (k in data) print data[k]}' "$OUTPUT_FILE" \
        | sort -t' ' -k2 -n > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
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

if [ "$clean_count" -gt 0 ]; then
    # Build reusable data once
    sorted_block=$(cat "$OUTPUT_FILE")
    dns_only_block=$(awk '{print $1}' "$OUTPUT_FILE")
    top8=$(head -n 8 "$OUTPUT_FILE" | awk '{print $1}' | paste -sd ',')

    # --- Terminal output ---
    printf "\n\n====== Sorted by latency ======\n\n"
    printf "%s\n" "$sorted_block"

    printf "\n\n====== DNS only (newline-separated) ======\n\n"
    printf "%s\n" "$dns_only_block"

    printf "\n\n====== Top 8 DNS (comma-separated) ======\n\n"
    printf "%s\n" "$top8"

    # --- Append all three formats to the output file ---
    {
        printf "\n\n====== Sorted by latency ======\n\n"
        printf "%s\n" "$sorted_block"

        printf "\n\n====== DNS only (newline-separated) ======\n\n"
        printf "%s\n" "$dns_only_block"

        printf "\n\n====== Top 8 DNS (comma-separated) ======\n\n"
        printf "%s\n" "$top8"
    } >> "$OUTPUT_FILE"
fi