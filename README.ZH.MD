# 🧩 ns-tun2socks

中文 | [English](README.MD)

**ns-tun2socks** 是一个轻量级的 Bash 脚本，用于在独立的网络环境中运行任意命令或服务，并通过 **SOCKS5 代理** 转发其全部网络流量。
你可以让某个特定程序（例如浏览器、下载器、服务器等）在受控代理环境中运行，而不影响系统的其他应用。

---

## 🚀 功能特性

* **自动创建隔离的网络环境**，只影响指定命令，不修改系统全局网络配置
* 支持 **go-tun2socks** 与 **badvpn-tun2socks** 自动检测切换
* 可使用 **rust-dns2socks** 实现 DNS 请求通过 SOCKS 转发（支持 TCP/UDP）
* 支持 **端口转发**、**直连策略**（可跳过特定端口或目标）
* 支持 **JSON 配置文件统一管理**
* 自动清理临时网络、路由与 iptables 规则
* 支持彩色日志、调试模式与详细运行记录

---

## 🧱 工作原理

1. 创建独立的虚拟网络环境
2. 在宿主机与该环境间建立虚拟接口
3. 通过 `tun2socks` 将该环境中的所有流量转发至 SOCKS5 代理
4. 可选启动 `dns2socks` 实现经代理的 DNS 查询
5. 自动设置直连策略与端口转发，避免循环代理
6. 启动目标程序，使其网络请求全部经 SOCKS 出口转发

---

## ⚙️ 依赖项安装

### 必需组件

* `bash` (>= 4.0)
* `jq`
* `iproute2`（提供 `ip` 命令）
* `socat`
* `iptables`

### 根据模式选择安装

| 模式                   | 需要的程序              | 官方仓库                                                                             |
| -------------------- | ------------------ | -------------------------------------------------------------------------------- |
| **go-tun2socks**     | `go-tun2socks`     | [https://github.com/xjasonlyu/tun2socks](https://github.com/xjasonlyu/tun2socks) |
| **badvpn-tun2socks** | `badvpn-tun2socks` | [https://github.com/ambrop72/badvpn](https://github.com/ambrop72/badvpn)         |
| **rust-dns2socks**   | `dns2socks`        | [https://github.com/tun2proxy/dns2socks](https://github.com/tun2proxy/dns2socks) |

---

### 🐧 Linux 安装示例

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install -y jq iproute2 socat iptables unzip

# Arch Linux
sudo pacman -S jq iproute2 socat iptables unzip

# 安装 go-tun2socks
sudo wget -O /tmp/tun2socks-linux-amd64.zip https://github.com/xjasonlyu/tun2socks/releases/download/v2.6.0/tun2socks-linux-amd64.zip

sudo unzip /tmp/tun2socks-linux-amd64.zip -d /tmp/

sudo mv /tmp/tun2socks-linux-amd64 /usr/local/bin/go-tun2socks

sudo chmod +x /usr/local/bin/go-tun2socks
```

---

## 📁 配置文件 (`ns_tun2socks.json`)

可选项，默认路径为 `./ns_tun2socks.json`

示例：

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

## 🧩 命令行参数

| 参数                                      | 说明                                            |
| --------------------------------------- | --------------------------------------------- |
| `--config <file>`                       | 指定配置文件路径（默认 `./ns_tun2socks.json`）            |
| `--socks <host:port>`                   | 指定 SOCKS5 代理地址（必填）                            |
| `--tun2socks <path>`                    | 指定 tun2socks 可执行文件路径                          |
| `--dns2socks <path>`                    | 指定 dns2socks 可执行文件路径                          |
| `--forward <host_port:ns_port[:proto]>` | 设置端口转发，例如 `8080:80` 或 `5300:53:udp`           |
| `--log-level <level>`                   | 日志级别：`DEBUG`、`INFO`、`WARN`、`ERROR`（默认 `NONE`） |
| `--`                                    | 之后的参数为要执行的目标命令                                |

---

## 🔧 使用示例

### 1️⃣ 为特定命令提供代理环境

```bash
sudo ./ns-tun2socks.sh --socks 127.0.0.1:1080 -- curl https://ifconfig.me
```

> 所有 `curl` 的网络请求将通过指定 SOCKS 代理发出。

---

### 2️⃣ 代理下运行 Web 服务

```bash
sudo ./ns-tun2socks.sh \
  --socks 127.0.0.1:1080 \
  --forward 8080:80 \
  --log-level info \
  -- /usr/bin/python3 -m http.server 80
```

> 本地访问 `http://127.0.0.1:8080` 时，请求将经 SOCKS 代理转发到远程。

---

### 3️⃣ 使用 badvpn 模式（带 DNS 转发）

```bash
sudo ./ns-tun2socks.sh \
  --socks 127.0.0.1:1080 \
  --tun2socks /usr/bin/badvpn-tun2socks \
  --dns2socks /usr/bin/rust-dns2socks \
  -- /bin/bash
```

> 启动交互式终端，所有命令的网络访问将通过 SOCKS 代理（含 DNS）。

---

## 🧹 清理逻辑

脚本退出时自动执行：

* 删除临时网络接口
* 清理路由规则与 iptables
* 终止后台代理进程
* 删除临时日志文件

即使异常退出，也会触发清理过程 (`trap cleanup`)。

---

## 🧾 日志与调试

日志颜色：

* `DEBUG`：青色
* `INFO`：绿色
* `WARN`：黄色
* `ERROR`：红色

启用调试模式：

```bash
--log-level debug
```

日志文件路径：

```
/tmp/tun2socks_<RANDOM>.log
/tmp/dns2socks_<RANDOM>.log
```

---

## ⚠️ 注意事项

* 必须以 **root 权限** 运行
* 脚本会修改路由与防火墙规则，请谨慎使用
* 某些系统需开启 `net.ipv4.ip_forward=1`
* 建议先在测试环境验证代理配置

---

## 🧰 常见问题（FAQ）

**Q:** 启动报错 “未找到 tun2socks 程序”？
**A:** 请确认已安装对应可执行文件，或使用 `--tun2socks` 指定路径。

**Q:** DNS 无法解析？
**A:** 使用 badvpn 模式时请确保提供 `--dns2socks`，并检查 53 端口监听状态。

**Q:** 出现代理循环？
**A:** 脚本会自动为 SOCKS 服务器 IP 设置直连路由，避免循环代理。

---

## 🏁 License

MIT License
Copyright (c) 2025 imxcstar