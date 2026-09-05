"""TCP/UDP peers for isolated namespace integration tests."""
import socket
import socketserver
import sys
import threading

mode, host, port, label = sys.argv[1:5]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
port = int(port)
payload = b"a2b-forward-regression:" + bytes(range(256)) * 4

if mode == "serve":
    class TCPHandler(socketserver.BaseRequestHandler):
        def handle(self):
            data = b""
            while len(data) < len(payload):
                part = self.request.recv(4096)
                if not part:
                    return
                data += part
            self.request.sendall(label.encode() + b":" + data)

    class UDPHandler(socketserver.BaseRequestHandler):
        def handle(self):
            data, connection = self.request
            connection.sendto(label.encode() + b":" + data, self.client_address)

    class TCPServer(socketserver.ThreadingTCPServer):
        address_family = family
        allow_reuse_address = True
        daemon_threads = True

    class UDPServer(socketserver.ThreadingUDPServer):
        address_family = family
        allow_reuse_address = True
        daemon_threads = True

    with TCPServer((host, port), TCPHandler) as tcp, UDPServer((host, port), UDPHandler) as udp:
        threading.Thread(target=udp.serve_forever, daemon=True).start()
        tcp.serve_forever()
else:
    with socket.socket(family, socket.SOCK_DGRAM if mode == "udp" else socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect((host, port))
        client.sendall(payload)
        expected = label.encode() + b":" + payload
        response = b""
        while len(response) < len(expected):
            part = client.recv(4096)
            if not part:
                break
            response += part
        if response != expected:
            raise SystemExit("unexpected peer response")
