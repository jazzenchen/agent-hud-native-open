"""Bounded read-only cancellation watch, translating PermissionTranscriptWatch."""
import json,os
from pathlib import Path


def shared_read(path):
    """Keep watching without preventing the client from rotating/deleting a log."""
    if os.name!='nt':return Path(path).open('rb')
    import ctypes,msvcrt
    from ctypes import wintypes
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE]
    kernel.CreateFileW.restype=wintypes.HANDLE
    handle=kernel.CreateFileW(str(path),0x80000000,7,None,3,0x80,None)
    if handle==wintypes.HANDLE(-1).value:raise ctypes.WinError(ctypes.get_last_error())
    try:descriptor=msvcrt.open_osfhandle(int(handle),os.O_RDONLY|os.O_BINARY)
    except Exception:
        kernel.CloseHandle.argtypes=[wintypes.HANDLE];kernel.CloseHandle(handle);raise
    return os.fdopen(descriptor,'rb')


class PermissionTranscriptWatch:
    HISTORY=4*1024*1024
    def __init__(self,payload):
        self.stream=None;self.partial=b'';self.calls=set()
        self.tool=payload.get('tool_name');self.inputs=payload.get('tool_input')
        path=payload.get('transcript_path')
        if not isinstance(path,str) or not isinstance(self.tool,str):return
        try:
            self.stream=shared_read(path);self.stream.seek(0,2)
            offset=max(0,self.stream.tell()-self.HISTORY);self.stream.seek(offset)
            if offset:self.stream.readline(self.HISTORY)
            # Past results settle past calls, never this new hook invocation.
            self.read(self.stream.read(self.HISTORY))
        except OSError:self.close()

    def read(self,data):
        self.partial+=data;lines=self.partial.split(b'\n');self.partial=lines.pop();settled=False
        if len(self.partial)>self.HISTORY:self.partial=b''
        for line in lines:
            if b'tool_use' not in line and b'tool_result' not in line:continue
            try:row=json.loads(line)
            except (ValueError,UnicodeError,RecursionError):continue
            message=row.get('message') if isinstance(row,dict) else None
            blocks=message.get('content') if isinstance(message,dict) else None
            if not isinstance(blocks,list):continue
            for block in blocks:
                if not isinstance(block,dict):continue
                if block.get('type')=='tool_use' and block.get('name')==self.tool and block.get('input')==self.inputs and isinstance(block.get('id'),str):
                    self.calls.add(block['id'])
                elif block.get('type')=='tool_result' and isinstance(block.get('tool_use_id'),str) and block['tool_use_id'] in self.calls:
                    self.calls.remove(block['tool_use_id']);settled=True
        return settled

    def poll(self):
        if self.stream is None:return False
        try:return self.read(self.stream.read(self.HISTORY))
        except OSError:self.close();return False

    def close(self):
        if self.stream is not None:self.stream.close();self.stream=None
        self.partial=b'';self.calls.clear()

    def __del__(self):self.close()
