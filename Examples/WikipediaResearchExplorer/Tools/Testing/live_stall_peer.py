# SPDX-License-Identifier: Apache-2.0
"""One finite loopback HTTP peer for native transport cancellation tests."""
import os,pathlib,socket,sys
root=pathlib.Path(sys.argv[1])
def publish(name,value):
 temporary=root/(name+'.tmp')
 with temporary.open('x') as output:output.write(value)
 os.replace(temporary,root/name)
listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind(('127.0.0.1',0));listener.listen(1);listener.settimeout(8)
publish('port',str(listener.getsockname()[1]))
try:
 conn,_=listener.accept();conn.settimeout(8)
 with conn:
  request=b''
  while b'\r\n\r\n' not in request:
   part=conn.recv(4096)
   if not part or len(request)+len(part)>16384:raise RuntimeError('incomplete request')
   request+=part
  if not request.startswith(b'GET /stall '):raise RuntimeError('unexpected request')
  conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n{"pages":')
  publish('sent','headers and partial body sent')
  try:
   remaining=conn.recv(1)
   result='eof' if not remaining else 'unexpected-data'
  except ConnectionResetError:result='reset'
  except socket.timeout:result='timeout'
  publish('closed',result)
finally:listener.close()
