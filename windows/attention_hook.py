"""Short-lived client callback. No HUD/unsupported input/disconnect = no opinion.

Never starts the HUD, changes client approvals, or stores tool input/reply text.
"""
import json,os,struct,sys,threading
from attention_protocol import LIMIT


def claude_headless():
    try:
        import psutil
        for parent in psutil.Process().parents()[:8]:
            args=parent.cmdline();name=parent.name().lower()
            if name in ('claude','claude.exe') or any('@anthropic-ai/claude-code/' in a.replace('\\','/') for a in args[:3]):
                return any(arg in ('-p','--print') for arg in args[1:])
    except Exception:pass
    return False


def send(kind,source,payload,pipe=None,wait=True):
    from PySide6.QtCore import QCoreApplication
    from PySide6.QtNetwork import QLocalSocket
    from attention_ipc import PIPE
    app=QCoreApplication.instance() or QCoreApplication([])
    socket=QLocalSocket();socket.connectToServer(pipe or PIPE)
    if not socket.waitForConnected(500):return b''
    raw=json.dumps(dict(kind=kind,source=source,payload=payload),ensure_ascii=False).encode()
    if len(raw)>LIMIT:socket.abort();return b''
    socket.write(struct.pack('!I',len(raw))+raw)
    if not socket.waitForBytesWritten(1000):socket.abort();return b''
    result=bytearray();parent=os.getppid()
    from permission_transcript import PermissionTranscriptWatch
    watch=PermissionTranscriptWatch(payload) if kind=='permission' and source=='claude' else None
    while socket.state()!=QLocalSocket.LocalSocketState.UnconnectedState:
        socket.waitForReadyRead(500)
        result.extend(bytes(socket.readAll()))
        if len(result)>LIMIT:socket.abort();return b''
        if watch is not None and watch.poll():socket.abort();watch.close();return b''
        if not wait:socket.disconnectFromServer();break
        # A killed/cancelled client must not leave an orphan approval waiting.
        try:
            import psutil
            if not psutil.pid_exists(parent):socket.abort();return b''
        except ImportError:pass
    result.extend(bytes(socket.readAll()))
    if watch is not None:watch.close()
    return bytes(result) if len(result)<=LIMIT else b''


def main():
    try:
        kind,source=sys.argv[1:3]
        # Match the source's five-second pre-wait alarm even when a client
        # forgets to close stdin. It must not hold the client's approval flow.
        deadline=threading.Timer(5,lambda:os._exit(0));deadline.daemon=True;deadline.start()
        data=sys.stdin.buffer.read(LIMIT+1);deadline.cancel()
        if len(data)>LIMIT:return
        payload=json.loads(data)
        if not isinstance(payload,dict):return
        if kind=='permission' and source=='claude' and claude_headless():return
        pipe=sys.argv[4] if len(sys.argv)>4 and sys.argv[3]=='--pipe' else None
        answer=send(kind,source,payload,pipe=pipe)
        if kind=='permission' and answer:sys.stdout.buffer.write(answer)
    except Exception:
        # No output preserves the client's own permission flow.
        return


if __name__=='__main__':main()
