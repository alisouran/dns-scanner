# DNSTT Scanner

**[Persian / فارسی <img src="https://upload.wikimedia.org/wikipedia/commons/b/bf/%D9%BE%D8%B1%DA%86%D9%85_%D8%A7%D8%B5%DB%8C%D9%84_%D8%A7%DB%8C%D8%B1%D8%A7%D9%86.png" height="14" alt="Lion and Sun Flag">](README.fa.md)**

A parallel DNS scanner that tests DNS servers for connectivity through
[dnstt](https://www.bamsoftware.com/software/dnstt/) tunneling. It checks
whether each DNS server can successfully establish a dnstt tunnel and classifies
them by status.

## How It Works

1. Reads a list of DNS server IPs or CIDR ranges from a file (CSV or TXT format)
   and automatically expands any CIDR notation (e.g., `10.0.0.0/24`) into
   individual host IPs
2. For each DNS server, launches a parallel worker that:
   - Starts a `dnstt-client` instance pointing at the DNS server
   - Attempts an SSH connection through the tunnel
   - Monitors both processes for success/failure indicators
3. Classifies each DNS server into one of four statuses:
   - **CLEAN** - Tunnel works, SSH handshake reached (DNS is usable)
   - **BLOCKED_BY_DPI** - Tunnel stream was created but SSH failed (likely deep
     packet inspection)
   - **DEAD** - No tunnel or connection could be established
   - **CRASH** - The dnstt-client process crashed immediately
4. Saves all clean/working DNS servers to a timestamped output file

## Prerequisites

- macOS (tested on ARM64) or Linux
- Python 3 (pre-installed on macOS and most Linux distributions; used for CIDR
  expansion)
- SSH client (pre-installed on macOS and most Linux distributions)
- A running dnstt server with its public key

## Step-by-Step Setup

### Step 1: Clone the Repository

```bash
git clone <repository-url>
cd dnsscanner

```

### Step 2: Download the dnstt-client Binary

The `dnstt-client` binary is required to test DNS tunneling. You need to
download the correct pre-built version for your operating system and
architecture.

**Download link:** https://dnstt.network/

_Note: The filename you download will vary depending on your system (e.g.,
`dnstt-client-darwin-arm64` for Apple Silicon Macs, or
`dnstt-client-linux-amd64` for standard Linux servers)._

**Where to put it:**

Move or copy the downloaded binary into the project root directory (the same
folder as `dns-scanner.sh`).

```bash
# Example for macOS Apple Silicon
cp dnstt-client-darwin-arm64 /path/to/dnsscanner/

```

Your project folder should look like this:

```
dnsscanner/
├── dns-scanner.sh
├── dnstt-client-darwin-arm64    <-- place the binary here
├── .env
├── .env.example
├── dns-list.txt
└── README.md

```

Make sure the binary is executable:

```bash
# Replace with your actual downloaded filename
chmod +x dnstt-client-darwin-arm64

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

Here is what each variable means: | Variable | Required | Description | | --- |
--- | --- | | `PUB_KEY` | Yes | The public key of your dnstt server. You get
this from whoever set up the server. | | `DNSTT_DOMAIN` | Yes | The domain name
configured for dnstt tunneling (e.g. `t.example.com`). | | `SSH_USER` | Yes |
SSH username on the tunnel server (usually `root`). | | `DNSTT_BIN` | Yes | Path
to the dnstt-client binary. **Make sure this exactly matches the file you
downloaded in Step 2** (e.g., `./dnstt-client-darwin-arm64` or
`./dnstt-client-linux-amd64`). | | `DNS_LIST_FILE` | Yes | Path to your DNS
server list file (`.csv` or `.txt`). | | `OUTPUT_FILE` | No | Custom output
filename. If not set, a timestamped file like
`working-dns_2026-03-04_16-30-00.txt` is created automatically. | |
`MAX_WAIT_TIME` | No | How many seconds to wait for each DNS check before giving
up (default: `45`). | | `BASE_PORT` | No | Starting local port number for worker
processes (default: `10000`). | | `MAX_PARALLEL` | No | How many DNS servers to
test at the same time (default: `5`). Increase for faster scans, decrease if you
have limited resources. |

### Step 4: Prepare Your DNS List

Create a file with the DNS server IPs or CIDR ranges you want to test. Both
individual IPs and CIDR notation are supported — CIDR ranges are automatically
expanded into individual host IPs at startup. Two file formats are supported:

**💡 Pro Tip: Finding DNS Servers** If you don't already have a list of DNS
servers, you can first use a tool like
[PYDNS-Scanner](https://github.com/xullexer/PYDNS-Scanner) to find active ones.
PYDNS-Scanner generates a `.csv` file as its output. You can simply copy that
exact CSV file into the root of this project and use it as your `DNS_LIST_FILE`
without making any modifications!

**TXT format** - one IP or CIDR range per line, `#` comments supported:

```
8.8.8.8
1.1.1.1
10.0.0.0/24
# This is a comment
172.16.0.0/28

```

**CSV format** - IP/CIDR in the first column, first row is treated as a header
and skipped:

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

The scanner will show a live progress bar and print clean results in real time
with color-coded latency. Each scan creates a new timestamped output file (e.g.
`working-dns_2026-03-04_16-30-00.txt`) so your previous results are always
preserved. Results are sorted by latency (fastest first).

## Output Example

```
Expanding 150 entries (CIDR ranges -> individual IPs)...
==================================================
  DNSTT Scanner (Parallel | Max 50 workers)
==================================================
  DNS list : dns-list.txt (1200 servers)
  Output   : working-dns_2026-03-04_16-30-00.txt
==================================================

 [ CLEAN ] 8.8.8.8 - 320ms
 [ CLEAN ] 9.9.9.9 - 870ms
[########------------] 40% (480/1200) | Running...

==================================================
  Done! 2/1200 servers are clean.
  Working DNS saved to: working-dns_2026-03-04_16-30-00.txt
==================================================

```

## Troubleshooting

| Problem                                     | Solution                                                                                                                       |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `Error: .env file not found`                | Run `cp .env.example .env` and fill in your values.                                                                            |
| `Error: PUB_KEY is not set`                 | Open `.env` and make sure all required variables are filled in.                                                                |
| `Permission denied` when running the script | Run `chmod +x dns-scanner.sh`                                                                                                  |
| `dnstt-client: command not found` or crash  | Make sure the binary exists at the path specified in `DNSTT_BIN` and is executable (`chmod +x`). **Check the exact filename!** |
| All servers show as DEAD                    | Check your internet connection and verify that `DNSTT_DOMAIN` and `PUB_KEY` are correct.                                       |
| Scans are too slow                          | Increase `MAX_PARALLEL` in `.env` (e.g. `10`), or decrease `MAX_WAIT_TIME`.                                                    |
