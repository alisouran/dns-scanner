# DNSTT Scanner

**[Persian / فارسی](README.fa.md)**

A parallel DNS scanner that tests DNS servers for connectivity through [dnstt](https://www.bamsoftware.com/software/dnstt/) tunneling. It checks whether each DNS server can successfully establish a dnstt tunnel and classifies them by status.

## How It Works

1. Reads a list of DNS server IPs from a file (CSV or TXT format)
2. For each DNS server, launches a parallel worker that:
   - Starts a `dnstt-client` instance pointing at the DNS server
   - Attempts an SSH connection through the tunnel
   - Monitors both processes for success/failure indicators
3. Classifies each DNS server into one of four statuses:
   - **CLEAN** - Tunnel works, SSH handshake reached (DNS is usable)
   - **BLOCKED_BY_DPI** - Tunnel stream was created but SSH failed (likely deep packet inspection)
   - **DEAD** - No tunnel or connection could be established
   - **CRASH** - The dnstt-client process crashed immediately
4. Saves all clean/working DNS servers to a timestamped output file

## Prerequisites

- macOS (tested on ARM64) or Linux
- SSH client (pre-installed on macOS and most Linux distributions)
- A running dnstt server with its public key

## Step-by-Step Setup

### Step 1: Clone the Repository

```bash
git clone <repository-url>
cd dnsscanner
```

### Step 2: Download the dnstt-client Binary

The `dnstt-client` binary is required to test DNS tunneling. You need to download the correct version for your operating system and architecture.

**Option A: Download a pre-built binary**

Go to the official dnstt page and download the appropriate binary:

https://www.bamsoftware.com/software/dnstt/

**Option B: Build from source**

If no pre-built binary is available for your platform, you can build it yourself. You need [Go](https://go.dev/dl/) installed:

```bash
git clone https://www.bamsoftware.com/git/dnstt.git
cd dnstt/dnstt-client
go build
```

This produces a `dnstt-client` binary in the current directory.

**Where to put it:**

Move or copy the binary into the project root directory (the same folder as `dns-scanner.sh`):

```bash
cp dnstt-client /path/to/dnsscanner/
```

Your project folder should look like this:

```
dnsscanner/
├── dns-scanner.sh
├── dnstt-client          <-- place the binary here
├── .env
├── .env.example
├── dns-list.txt
└── README.md
```

Make sure the binary is executable:

```bash
chmod +x dnstt-client
```

### Step 3: Configure the Environment

1. Copy the example environment file:

   ```bash
   cp .env.example .env
   ```

2. Open `.env` in a text editor and fill in your values:

   ```bash
   nano .env
   ```

   Here is what each variable means:

   | Variable | Required | Description |
   |---|---|---|
   | `PUB_KEY` | Yes | The public key of your dnstt server. You get this from whoever set up the server. |
   | `DNSTT_DOMAIN` | Yes | The domain name configured for dnstt tunneling (e.g. `t.example.com`). |
   | `SSH_USER` | Yes | SSH username on the tunnel server (usually `root`). |
   | `DNSTT_BIN` | Yes | Path to the dnstt-client binary. If you placed it in the project folder, use `./dnstt-client` (or `./dnstt-client-darwin-arm64` if that's the filename). |
   | `DNS_LIST_FILE` | Yes | Path to your DNS server list file (`.csv` or `.txt`). |
   | `OUTPUT_FILE` | No | Custom output filename. If not set, a timestamped file like `working-dns_2026-03-04_16-30-00.txt` is created automatically. |
   | `MAX_WAIT_TIME` | No | How many seconds to wait for each DNS check before giving up (default: `45`). |
   | `BASE_PORT` | No | Starting local port number for worker processes (default: `10000`). |
   | `MAX_PARALLEL` | No | How many DNS servers to test at the same time (default: `5`). Increase for faster scans, decrease if you have limited resources. |

### Step 4: Prepare Your DNS List

Create a file with the DNS server IPs you want to test. Two formats are supported:

**TXT format** - one IP per line, `#` comments supported:

```
8.8.8.8
1.1.1.1
# This is a comment
9.9.9.9
```

**CSV format** - IP in the first column, first row is treated as a header and skipped:

```csv
ip,provider,country
8.8.8.8,Google,US
1.1.1.1,Cloudflare,US
```

Save this file and make sure `DNS_LIST_FILE` in your `.env` points to it.

### Step 5: Run the Scanner

```bash
chmod +x dns-scanner.sh
./dns-scanner.sh
```

The scanner will test each DNS server and show results in the terminal with color-coded statuses. Each scan creates a new timestamped output file (e.g. `working-dns_2026-03-04_16-30-00.txt`) so your previous results are always preserved.

## Output Example

```
==================================================
  DNSTT Scanner (Parallel | Max 5 workers)
==================================================
  DNS list : dns-list.txt (3 servers)
  Output   : working-dns_2026-03-04_16-30-00.txt
==================================================

 [ CLEAN ] 8.8.8.8
 [ BLOCKED BY DPI ] 1.1.1.1
 [ DEAD ] 9.9.9.9

==================================================
  Done! 1/3 servers are clean.
  Working DNS saved to: working-dns_2026-03-04_16-30-00.txt
==================================================
```

## Troubleshooting

| Problem | Solution |
|---|---|
| `Error: .env file not found` | Run `cp .env.example .env` and fill in your values. |
| `Error: PUB_KEY is not set` | Open `.env` and make sure all required variables are filled in. |
| `Permission denied` when running the script | Run `chmod +x dns-scanner.sh` |
| `dnstt-client: command not found` or crash | Make sure the binary exists at the path specified in `DNSTT_BIN` and is executable (`chmod +x`). |
| All servers show as DEAD | Check your internet connection and verify that `DNSTT_DOMAIN` and `PUB_KEY` are correct. |
| Scans are too slow | Increase `MAX_PARALLEL` in `.env` (e.g. `10`), or decrease `MAX_WAIT_TIME`. |
