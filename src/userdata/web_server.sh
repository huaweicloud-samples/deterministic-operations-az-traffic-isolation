#!/bin/bash
# ---------------------------------------------------------------------------
# 可用区隔离实践 —— 后端服务启动脚本
#
# 由 Terraform 的 templatefile 在部署时注入以下四个值：
#   app_port         后端监听端口
#   az_suffix        可用区后缀（1/2/3），用于标识实例属于哪个可用区
#   az_name          可用区全称（如 cn-north-4a）
#   health_check_path 健康检查路径
#
# 实例上跑的是一个只用标准库写的 HTTP 服务，响应里带上自己的可用区编号。
# 验证撤离效果时，靠的就是观察返回内容里可用区编号的分布变化。
# ---------------------------------------------------------------------------
set -euo pipefail

PY=/opt/az_web_server.py

cat > "$PY" <<'PYEOF'
import json
import http.server
import socketserver

PORT = ${app_port}
AZ_SUFFIX = "${az_suffix}"
AZ_NAME = "${az_name}"
HEALTH_PATH = "${health_check_path}"


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == HEALTH_PATH:
            self._send(200, {"status": "ok"})
            return
        self._send(200, {
            "az_suffix": AZ_SUFFIX,
            "az_name": AZ_NAME,
            "port": PORT,
            "path": self.path,
        })

    def log_message(self, *args):
        return


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("", PORT), Handler) as httpd:
        httpd.serve_forever()
PYEOF

cat > /etc/systemd/system/az-web.service <<'UNITEOF'
[Unit]
Description=AZ isolation demo web server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/az_web_server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now az-web.service
