# Media Library 线上部署与更新指南

本文档记录 `media_library` 服务端在云主机上的部署架构与日常更新流程，方便后续一键构建、发布和排障。

---

## 1. 线上环境概览

- **服务器**：`47.76.108.192`（Debian 12 x86_64，SSH 端口 `22`，本地通过 `127.0.0.1:7897` SOCKS5 代理连接；凭据见本地 `E:\SSH\47.76.108.192.txt`）
- **访问域名**：`https://play.ttai.net`（Cloudflare `A` 记录，已开启 Proxied ☁️，SSL 模式为 `full`；凭据见本地 `E:\SSH\CF\credentials.json`）
- **服务器目录结构**：
  - `/opt/media-library/media-library`：Go 静态可执行文件
  - `/opt/media-library/web/dist/`：React Web 管理后台静态构建产物
  - `/opt/media-library/data/`：持久化数据目录（`library.db`、`master.key`、`artwork_cache/`、`logs/`）
- **Systemd 服务**：`/etc/systemd/system/media-library.service`
  - 启动参数：`-addr 127.0.0.1:8090 -data-dir /opt/media-library/data -web-dir /opt/media-library/web/dist -trusted-proxies 127.0.0.1/32 -allow-insecure-credentials=true -log-level info`
- **Nginx 反向代理**：`/etc/nginx/sites-available/play.ttai.net`
  - 监听 `80` 和 `443 ssl`（自签名证书 `/etc/nginx/ssl/play.ttai.net.crt` 供 Cloudflare `full` 模式回源）
  - 转发至 `http://127.0.0.1:8090`，已关闭 `proxy_buffering` 并将超时设为 `3600s` 以支持 `/api/v1/events` SSE 长连接。

---

## 2. 日常更新流程

### 场景 A：仅更新前端 Web UI（`media_library/web`）

> 后端直接从 `-web-dir` 读取静态文件，仅更新前端时**无需重启** `media-library` 服务。

1. **本地构建前端**：
   ```powershell
   cd e:\Code\plezy\media_library\web
   npm run build
   ```
2. **打包并上传替换 `/opt/media-library/web/dist`**：
   - 将 `e:\Code\plezy\media_library\web\dist` 打成 `web_dist.tar.gz`（根目录为 `dist/`）。
   - 通过本地 `127.0.0.1:7897` 代理上传至 `/tmp/web_dist.tar.gz`，在服务器执行：
     ```bash
     rm -rf /opt/media-library/web/dist \
       && tar -xzf /tmp/web_dist.tar.gz -C /opt/media-library/web \
       && rm -f /tmp/web_dist.tar.gz
     ```
3. **验证**：
   ```bash
   curl -s http://127.0.0.1:8090/ | grep -o 'index-[A-Za-z0-9_-]*\.js'
   ```

---

### 场景 B：更新后端 Go 服务（或前后端全量更新）

1. **本地测试与前端构建**：
   ```powershell
   cd e:\Code\plezy\media_library\web
   npm run build

   cd e:\Code\plezy\media_library
   go test ./...
   ```
2. **交叉编译 Linux amd64 静态二进制**：
   ```powershell
   cd e:\Code\plezy\media_library
   $env:HTTP_PROXY = "http://127.0.0.1:7897"
   $env:HTTPS_PROXY = "http://127.0.0.1:7897"
   $env:CGO_ENABLED = "0"
   $env:GOOS = "linux"
   $env:GOARCH = "amd64"
   go build -trimpath -ldflags="-s -w" -o .\dist-linux\media-library ./cmd/media-library
   ```
3. **上传并原子替换重启**：
   - 将新二进制上传至服务器 `/tmp/media-library.new`（若有前端改动同步上传 `/tmp/web_dist.tar.gz`）。
   - 在服务器执行：
     ```bash
     chmod +x /tmp/media-library.new
     systemctl stop media-library
     cp /opt/media-library/media-library /opt/media-library/media-library.bak
     mv /tmp/media-library.new /opt/media-library/media-library

     # 如有前端更新：
     # rm -rf /opt/media-library/web/dist && tar -xzf /tmp/web_dist.tar.gz -C /opt/media-library/web && rm -f /tmp/web_dist.tar.gz

     systemctl start media-library
     systemctl status media-library --no-pager
     ```
4. **验证健康检查**：
   ```bash
   curl -s http://127.0.0.1:8090/api/v1/health
   # 预期输出: {"code":0,"role":"media_library","status":"ok"}
   ```
   公网端到端验证（注意携带浏览器 `User-Agent`，避免触发 Cloudflare 1010 拦截）：
   ```powershell
   curl.exe -x http://127.0.0.1:7897 -A "Mozilla/5.0" -s https://play.ttai.net/api/v1/health
   ```

---

### 场景 C：快速回滚（后端异常时）

```bash
systemctl stop media-library
mv /opt/media-library/media-library.bak /opt/media-library/media-library
systemctl start media-library
```

---

## 3. 通过本地 `7897` 代理连接服务器的 Python 模板

由于本机通过 `127.0.0.1:7897` SOCKS5 代理连入目标服务器 `22` 端口，且已安装 `paramiko`，可直接用如下脚本片段建立 SSH/SFTP 会话（凭据从 `E:\SSH\47.76.108.192.txt` 读取，切勿将密码硬编码进仓库）：

```python
import socket, struct, paramiko

lines = [l.strip() for l in open(r"E:\SSH\47.76.108.192.txt", encoding="utf-8").read().splitlines() if l.strip()]
host = lines[0].split(":")[0]
user, pwd = lines[1], lines[2]

s = socket.create_connection(("127.0.0.1", 7897), timeout=15)
s.sendall(b"\x05\x01\x00")
assert s.recv(2) == b"\x05\x00"
s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(host) + struct.pack("!H", 22))
assert s.recv(10)[:2] == b"\x05\x00"

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(host, port=22, username=user, password=pwd, sock=s, timeout=15)
```

---

## 4. 常用运维与数据备份

- **查看实时日志**：`journalctl -u media-library -f`
- **重载 Nginx**：`nginx -t && systemctl reload nginx`
- **重要数据**：升级或迁移前务必保留 `/opt/media-library/data/library.db` 与 `/opt/media-library/data/master.key`（缺少 `master.key` 将无法解密库中保存的 API Key 与源凭证）。
