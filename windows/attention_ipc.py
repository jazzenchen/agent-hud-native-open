"""Current-user named-pipe bridge, replacing the original Unix permission socket."""
import json,struct,time
from collections import OrderedDict
from PySide6.QtCore import QObject,Signal,QTimer
from PySide6.QtNetwork import QLocalServer
from attention_protocol import LIMIT,permission,completion,decision,CompletionTracker

PIPE='agent-hud-open-attention-v1'


class AttentionServer(QObject):
    changed=Signal()
    def __init__(self,parent=None,enabled=lambda:True,name=PIPE,wait_minutes=lambda:10,completion_enabled=lambda _:True):
        super().__init__(parent);self.enabled=enabled;self.wait_minutes=wait_minutes;self.completion_enabled=completion_enabled;self.pending=OrderedDict();self.connections={}
        self.seen=OrderedDict();self.tracker=CompletionTracker();self.server=QLocalServer(self)
        self.server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
        self.listening=self.server.listen(name)
        self.server.newConnection.connect(self.accept)

    def accept(self):
        while self.server.hasPendingConnections():
            socket=self.server.nextPendingConnection()
            if len(self.connections)>=64:socket.disconnectFromServer();socket.deleteLater();continue
            timer=QTimer(socket);timer.setSingleShot(True);timer.setInterval(5000)
            state=dict(buffer=bytearray(),size=None,id=None,timer=timer)
            self.connections[socket]=state
            socket.readyRead.connect(lambda socket=socket:self.read(socket))
            socket.disconnected.connect(lambda socket=socket:self.withdraw(socket))
            timer.timeout.connect(lambda socket=socket:self.release(socket))
            timer.start();self.read(socket)

    def read(self,socket):
        state=self.connections.get(socket)
        if state is None:return
        chunk=bytes(socket.readAll())
        if state['id'] is not None:
            if chunk:self.release(socket)
            return
        state['buffer'].extend(chunk)
        if len(state['buffer'])>LIMIT+4:self.release(socket);return
        if state['size'] is None and len(state['buffer'])>=4:
            state['size']=struct.unpack('!I',state['buffer'][:4])[0]
            if not 0<state['size']<=LIMIT:self.release(socket);return
        size=state['size']
        if size is None or len(state['buffer'])<size+4:return
        if len(state['buffer'])!=size+4 or not self.enabled():self.release(socket);return
        try:
            envelope=json.loads(state['buffer'][4:]);state['buffer'].clear()
            if not isinstance(envelope,dict):raise ValueError('Invalid envelope')
            source=envelope.get('source');payload=envelope.get('payload');kind=envelope.get('kind')
            event=permission(source,payload) if kind=='permission' else completion(source,payload) if kind=='completion' else None
        except Exception:event=None
        if event is None:self.release(socket);return
        state['timer'].stop()
        if event['kind']=='completion':
            self.add_completion(event);socket.write(b'{}');self.release(socket);return
        if len(self.pending)>=64:self.release(socket);return
        event['_socket']=socket;state['id']=event['id'];self.pending[event['id']]=event
        state['since']=time.monotonic()
        state['timer'].setInterval(max(1,round(self.wait_minutes()*60000)));state['timer'].start();self.changed.emit()

    def refresh_wait(self):
        for state in self.connections.values():
            if state['id']:
                remaining=self.wait_minutes()*60000-(time.monotonic()-state['since'])*1000
                state['timer'].start(max(1,round(remaining)))

    def add_completion(self,event):
        if not self.enabled() or not self.completion_enabled(event['vendor']):return
        # A hook and a log transition can describe the same completed turn.
        key=(event['vendor'],event['session'],event.get('turn'))
        recent=(event['vendor'],event['session'])
        now=time.monotonic()
        if key in self.seen or any((item['vendor'],item['session'])==recent and abs(item['at']-event['at'])<3 for item in self.pending.values() if item['kind']=='completion'):return
        self.seen[key]=now
        while len(self.seen)>512:self.seen.popitem(last=False)
        # Never evict a pending permission to make room for a notification.
        if len(self.pending)>=64:
            old=next((k for k,v in self.pending.items() if v['kind']=='completion'),None)
            if old is None:return
            self.pending.pop(old)
        self.pending[event['id']]=event;self.changed.emit()

    def observe(self,snapshot):
        for event in self.tracker.update(snapshot):self.add_completion(event)

    def resolve(self,identifier,action,**options):
        event=self.pending.get(identifier)
        if event is None:return
        if event['kind']=='completion':self.pending.pop(identifier);self.changed.emit();return
        answer=decision(event,action,**options)
        # Unsupported answers do not silently become approval or lose the card.
        if not answer and action!='leave':return
        socket=event.get('_socket');self.pending.pop(identifier,None)
        if socket in self.connections:
            self.connections[socket]['id']=None
            if answer:socket.write(answer)
            self.release(socket)
        self.changed.emit()

    def release(self,socket):
        if socket not in self.connections:return
        self.connections[socket]['timer'].stop()
        socket.flush();socket.disconnectFromServer()
        # disconnectFromServer drains pending bytes. Destroying the socket here
        # would truncate a larger question/plan answer before the hook reads it.
        from PySide6.QtNetwork import QLocalSocket
        if socket.state()==QLocalSocket.LocalSocketState.UnconnectedState:self.withdraw(socket)
        else:
            self.connections[socket]['timer'].setInterval(5000)
            self.connections[socket]['timer'].timeout.connect(socket.abort)
            self.connections[socket]['timer'].start()

    def withdraw(self,socket):
        state=self.connections.pop(socket,None)
        if state:
            state['timer'].stop();identifier=state['id']
            if identifier and self.pending.pop(identifier,None) is not None:self.changed.emit()
            socket.deleteLater()

    def disable(self):
        for socket in tuple(self.connections):self.release(socket)
        self.pending.clear();self.changed.emit()

    def close(self):self.disable();self.server.close()
