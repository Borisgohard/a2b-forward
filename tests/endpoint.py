"""HTTP/UDP endpoints used only inside isolated Linux network namespaces."""
import http.server
import json
import socket
import sys
import threading

host, port, marker = sys.argv[1], int(sys.argv[2]), sys.argv[3]
family = socket.AF_INET6 if ":" in host else socket.AF_INET


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"marker": marker, "peer": self.client_address[0]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class Server(http.server.ThreadingHTTPServer):
    address_family = family

    def server_bind(self):
        if family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


def udp():
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((host, port))
        while True:
            data, peer = sock.recvfrom(65535)
            sock.sendto(marker.encode() + b":" + data, peer)


threading.Thread(target=udp, daemon=True).start()
Server((host, port), Handler).serve_forever()
