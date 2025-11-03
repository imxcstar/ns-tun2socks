# 🧩 ns-tun2socks

[中文](README.ZH.MD) | English

**ns-tun2socks** is a lightweight Bash script that runs any command or service in an isolated network namespace, forwarding all of its network traffic through a **SOCKS5 proxy**.
You can make a specific program (e.g., browser, downloader, server, etc.) operate entirely within a controlled proxy environment — without affecting your system-wide network settings.

---

## 🚀 Features

* **Automatically creates an isolated network environment** — only affects the target command, not the entire system.
* Supports **go-tun2socks** and **badvpn-tun2socks** with automatic detection and switching.
* Optionally uses **rust-dns2socks** to forward DNS requests through the SOCKS proxy (supports TCP/UDP).
* Supports **port forwarding** and **bypass policies** (skip specific ports or destinations).
* **JSON configuration file** for unified management.
* Automatically cleans up temporary networks, routes, and iptables rules.
* Colorful logging, debug mode, and detailed runtime logs.

---

## 🧱 How It Works

1. Creates an isolated virtual network environment.
2. Establishes a virtual interface between the host and the namespace.
3. Uses `tun2socks` to forward all traffic in that environment through the SOCKS5 proxy.
4. Optionally starts `dns2socks` for proxy-based DNS resolution.
5. Sets up bypass and forwarding rules to prevent proxy loops.
6. Runs the target command — all its traffic goes through the SOCKS proxy.

---

## ⚙️ Dependencies

### Required Packages

* `bash` (>= 4.0)
* `jq`
* `iproute2` (provides the `ip` command)
* `socat`
* `iptables`

### Mode-Specific Programs

| Mode                 | Required Program   | Official Repository                                                              |
| -------------------- | ------------------ | -------------------------------------------------------------------------------- |
| **go-tun2socks**     | `go-tun2socks`     | [https://github.com/xjasonlyu/tun2socks](https://github.com/xjasonlyu/tun2socks) |
| **badvpn-tun2socks** | `badvpn-tun2socks` | [https://github.com/ambrop72/badvpn](https://github.com/ambrop72/badvpn)         |
| **rust-dns2socks**   | `dns2socks`        | [https://github.com/tun2proxy/dns2socks](https://github.com/tun2proxy/dns2socks) |

---

### 🐧 Linux Installation Example

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install -y jq iproute2 socat iptables unzip

# Arch Linux
sudo pacman -S jq iproute2 socat iptables unzip

# Install go-tun2socks
sudo wget -O /tmp/tun2socks-linux-amd64.zip https://github.com/xjasonlyu/tun2socks/releases/download/v2.6.0/tun2socks-linux-amd64.zip
sudo unzip /tmp/tun2socks-linux-amd64.zip -d /tmp/
sudo mv /tmp/tun2socks-linux-amd64 /usr/local/bin/go-tun2socks
sudo chmod +x /usr/local/bin/go-tun2socks
```

---

## 📁 Configuration File (`ns_tun2socks.json`)

Optional — default path: `./ns_tun2socks.json`

Example:

```json
{
  "socks": "127.0.0.1:1080",
  "udp": false,
  "tun2socks": "/usr/local/bin/go-tun2socks",
  "dns2socks": "/usr/local/bin/rust-dns2socks",
  "bypass_dests": ["192.168.0.0/16", "10.0.0.0/8"],
  "bypass_ports": [22, 53],
  "forwards": ["8080:80", "5300:53:udp"]
}
```

---

## 🧩 Command-Line Options

| Option                                  | Description                                                  |
| --------------------------------------- | ------------------------------------------------------------ |
| `--config <file>`                       | Specify config file path (default `./ns_tun2socks.json`)     |
| `--socks <host:port>`                   | SOCKS5 proxy address (required)                              |
| `--tun2socks <path>`                    | Path to tun2socks executable                                 |
| `--dns2socks <path>`                    | Path to dns2socks executable                                 |
| `--forward <host_port:ns_port[:proto]>` | Set up port forwarding, e.g., `8080:80` or `5300:53:udp`     |
| `--log-level <level>`                   | Log level: `DEBUG`, `INFO`, `WARN`, `ERROR` (default `NONE`) |
| `--`                                    | Arguments following this are the target command to run       |

---

## 🔧 Usage Examples

### 1️⃣ Run a Command with Proxy Isolation

```bash
sudo ./ns-tun2socks.sh --socks 127.0.0.1:1080 -- curl https://ifconfig.me
```

> All `curl` network traffic will go through the specified SOCKS proxy.

---

### 2️⃣ Run a Web Server Behind a Proxy

```bash
sudo ./ns-tun2socks.sh \
  --socks 127.0.0.1:1080 \
  --forward 8080:80 \
  --log-level info \
  -- /usr/bin/python3 -m http.server 80
```

> Visiting `http://127.0.0.1:8080` locally routes requests through the SOCKS proxy to the remote endpoint.

---

### 3️⃣ Use badvpn Mode (with DNS Forwarding)

```bash
sudo ./ns-tun2socks.sh \
  --socks 127.0.0.1:1080 \
  --tun2socks /usr/bin/badvpn-tun2socks \
  --dns2socks /usr/bin/rust-dns2socks \
  -- /bin/bash
```

> Launches an interactive shell — all commands use the SOCKS proxy (including DNS).

---

## 🧹 Cleanup Logic

When the script exits, it automatically:

* Removes temporary network interfaces
* Cleans up routing and iptables rules
* Terminates background proxy processes
* Deletes temporary log files

Even in case of abnormal exit, cleanup is triggered via `trap cleanup`.

---

## 🧾 Logging & Debugging

Log colors:

* `DEBUG`: Cyan
* `INFO`: Green
* `WARN`: Yellow
* `ERROR`: Red

Enable debug mode:

```bash
--log-level debug
```

Log files:

```
/tmp/tun2socks_<RANDOM>.log
/tmp/dns2socks_<RANDOM>.log
```

---

## ⚠️ Notes

* Must be run as **root**.
* Modifies routing and firewall rules — use with caution.
* Some systems require `net.ipv4.ip_forward=1`.
* Always test proxy configuration in a safe environment first.

---

## 🧰 FAQ

**Q:** “tun2socks not found”?
**A:** Ensure the executable is installed or specify its path via `--tun2socks`.

**Q:** DNS resolution fails?
**A:** When using badvpn mode, make sure to provide `--dns2socks` and check port 53 bindings.

**Q:** Proxy loop detected?
**A:** The script automatically adds direct routes for the SOCKS server to avoid recursion.

---

## 🏁 License

MIT License
Copyright (c) 2025 imxcstar