"""MCPAppChannel / MCPAppClient via current-user Windows named pipes.

One length-prefixed request/reply per connection; no app/client startup, file
requests, network listeners or provider reads. Call handlers run on Qt's thread.
"""
import hashlib,struct,time
from PySide6.QtCore import QObject,QTimer,QCoreApplication
from PySide6.QtNetwork import QLocalServer,QLocalSocket
from mcp_protocol import line,parse,validate_reply

REQUEST_LIMIT=1024*1024
REPLY_LIMIT=16*1024*1024


def pipe_name():
    from providers import DATA
    scope=hashlib.sha256(str(DATA.absolute()).casefold().encode('utf-8')).hexdigest()[:16]
    return 'agent-hud-open-mcp-v1-'+scope


def frame(value,limit):
    data=line(value).encode('utf-8')
    if len(data)>limit:raise ValueError('Frame too large')
    return struct.pack('!I',len(data))+data


def call(request,name=None,timeout=10):
    try:encoded=frame(request,REQUEST_LIMIT)
    except (ValueError,TypeError):return {'ok':False,'error':'The call is larger than Agent HUD reads. Send less in one call.'}
    app=QCoreApplication.instance() or QCoreApplication([])
    socket=QLocalSocket();socket.setReadBufferSize(REPLY_LIMIT+5)
    deadline=time.monotonic()+max(.001,timeout)
    remaining=lambda:max(1,int((deadline-time.monotonic())*1000))
    try:
        socket.connectToServer(name or pipe_name())
        if not socket.waitForConnected(min(500,remaining())):return {'state':'notRunning'}
        socket.write(encoded);socket.flush()
        while socket.bytesToWrite():
            if time.monotonic()>=deadline or not socket.waitForBytesWritten(remaining()):return {'state':'unanswered'}
        data=bytearray();expected=None
        while time.monotonic()<deadline:
            data.extend(bytes(socket.readAll()))
            if len(data)>REPLY_LIMIT+4:return {'state':'unanswered'}
            if expected is None and len(data)>=4:
                expected=struct.unpack('!I',data[:4])[0]
                if not 0<expected<=REPLY_LIMIT:return {'state':'unanswered'}
            if expected is not None and len(data)>=expected+4:
                if len(data)!=expected+4:return {'state':'unanswered'}
                try:return validate_reply(parse(bytes(data[4:]))) or {'state':'unanswered'}
                except (ValueError,UnicodeError,RecursionError):return {'state':'unanswered'}
            if socket.state()==QLocalSocket.LocalSocketState.UnconnectedState:break
            socket.waitForReadyRead(remaining())
        return {'state':'unanswered'}
    finally:socket.abort()


class AppChannel(QObject):
    def __init__(self,handler,parent=None,name=None,enabled=lambda:True):
        super().__init__(parent);self.handler=handler;self.enabled=enabled;self.connections={}
        self.server=QLocalServer(self);self.server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
        self.listening=self.server.listen(name or pipe_name())
        self.server.newConnection.connect(self.accept)
    def close(self):
        self.server.close()
        for socket in list(self.connections):self.release(socket)
    def release(self,socket):
        state=self.connections.pop(socket,None)
        if state:state['timer'].stop()
        socket.abort();socket.deleteLater()
    def accept(self):
        while self.server.hasPendingConnections():
            socket=self.server.nextPendingConnection();socket.setReadBufferSize(REQUEST_LIMIT+5)
            if len(self.connections)>=32:self.release(socket);continue
            timer=QTimer(socket);timer.setSingleShot(True);timer.setInterval(5000)
            self.connections[socket]=dict(buffer=bytearray(),size=None,timer=timer)
            socket.readyRead.connect(lambda socket=socket:self.read(socket))
            socket.disconnected.connect(lambda socket=socket:self.release(socket) if socket in self.connections else None)
            timer.timeout.connect(lambda socket=socket:self.release(socket))
            timer.start();self.read(socket)
    def read(self,socket):
        state=self.connections.get(socket)
        if state is None:return
        if state.get('sent'):return
        state['buffer'].extend(bytes(socket.readAll()));data=state['buffer']
        if len(data)>REQUEST_LIMIT+4:self.release(socket);return
        if state['size'] is None and len(data)>=4:
            state['size']=struct.unpack('!I',data[:4])[0]
            if not 0<state['size']<=REQUEST_LIMIT:self.release(socket);return
        if state['size'] is None or len(data)<state['size']+4:return
        if len(data)!=state['size']+4:self.release(socket);return
        state['timer'].stop()
        if not self.enabled():reply={'state':'off'}
        else:
            try:
                request=parse(bytes(data[4:]))
                if not isinstance(request,dict):reply={'ok':False,'error':'The request is not a JSON object.'}
                elif not isinstance(request.get('tool'),str) or not request['tool']:reply={'ok':False,'error':'The request names no tool.'}
                elif request.get('arguments') is not None and not isinstance(request['arguments'],dict):reply={'ok':False,'error':"The request's arguments are not a JSON object."}
                else:reply=self.handler(dict(tool=request['tool'],arguments=request.get('arguments') or {}))
            except (ValueError,UnicodeError,RecursionError):reply={'ok':False,'error':'The request is not a JSON object.'}
            except Exception:reply={'ok':False,'error':'The call could not be read.'}
        try:encoded=frame(reply,REPLY_LIMIT)
        except (ValueError,TypeError):encoded=frame({'ok':False,'error':'The reply could not be written.'},REPLY_LIMIT)
        state['sent']=True;state['buffer'].clear()
        state['timer'].setInterval(10000);state['timer'].start()
        socket.write(encoded);socket.disconnectFromServer()
        if socket.state()==QLocalSocket.LocalSocketState.UnconnectedState:self.release(socket)
