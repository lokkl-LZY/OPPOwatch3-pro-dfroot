#!/usr/bin/env python3
"""check_rootshell.py [port] —— 连一次 root shell 并打印 id -u"""
import socket, sys, time
port = int(sys.argv[1]) if len(sys.argv) > 1 else 5556
try:
    s = socket.create_connection(('127.0.0.1', port), 5)
    time.sleep(0.2)
    s.sendall(b'id -u\n')
    time.sleep(0.6)
    sys.stdout.write(s.recv(4096).decode('utf-8', 'replace').replace('\r', '').strip())
    s.close()
except Exception as e:
    sys.stdout.write('ERR ' + str(e))
