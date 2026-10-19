"""Safe quota failure states: never confuse a failed read with exhausted usage."""
import errno
import socket
import sqlite3
import urllib.error


class QuotaError(RuntimeError):
    def __init__(self, code):
        self.code=code
        super().__init__(code)


def failure_code(error):
    if isinstance(error,QuotaError):return error.code
    if isinstance(error,urllib.error.HTTPError):
        return 'auth' if error.code in (401,403) else 'throttled' if error.code==429 else 'network'
    if isinstance(error,(TimeoutError,socket.timeout)):return 'timeout'
    if isinstance(error,urllib.error.URLError):return 'network'
    if isinstance(error,sqlite3.Error):return 'local_storage'
    if isinstance(error,OSError):return 'disk_full' if error.errno==errno.ENOSPC or getattr(error,'winerror',None)==112 else 'local_storage'
    # Classify known messages only; arbitrary upstream text never reaches logs/UI.
    message=str(error).lower()
    if any(word in message for word in ('expired','sign in','sign-in','authentication','unauthorized','login')):return 'auth'
    if 'timed out' in message:return 'timeout'
    if 'not found' in message:return 'missing_engine'
    return 'unavailable'


def notice(code,client='Codex'):
    return {'loading':'正在读取额度…','auth':f'请在 {client} 中重新登录后重试',
        'network':'额度连接失败，正在重试','timeout':'额度读取超时，正在重试',
        'throttled':'额度接口请求频繁，稍后自动重试','disk_full':'磁盘空间不足，无法读取额度',
        'local_storage':'本地记录暂时无法读取','missing_engine':'未找到客户端额度组件',
        'unavailable':'额度读取失败，正在重试','no_percentage':'账户未提供额度百分比'}.get(code,'额度读取失败，正在重试')


def quota_notice(data,client='Codex'):
    if data.get('hidden'):return '额度窗口已隐藏，可在智能体设置中恢复'
    if data.get('stale'):return '上次读数 · '+notice(data.get('error_code','unavailable'),client)
    if data.get('windows'):return ''
    return notice(data.get('error_code','loading' if not data.get('at') else 'no_percentage'),client)
