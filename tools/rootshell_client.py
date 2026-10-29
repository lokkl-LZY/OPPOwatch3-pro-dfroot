#!/usr/bin/env python3
"""rootshell_client.py [port] —— 连上 adb forward 的 root shell（127.0.0.1）
用法: 先 adb forward tcp:5556 tcp:5555, 再 python rootshell_client.py 5556
"""
import socket, sys, threading

port = int(sys.argv[1]) if len(sys.argv) > 1 else 5556
try:
    s = socket.create_connection(('127.0.0.1', port), 10)
except Exception as e:
    print('[x] connect failed:', e)
    sys.exit(1)

def rx():
    while True:
        try:
            d = s.recv(4096)
        except Exception:
            break
        if not d:
            break
        sys.stdout.buffer.write(d)
        sys.stdout.flush()

threading.Thread(target=rx, daemon=True).start()
print('[+] root shell connected. Ctrl-D / exit 退出.')
try:
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            break
        s.sendall(line)
finally:
    try:
        s.close()
    except Exception:
        pass
