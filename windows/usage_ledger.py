"""Source SessionLedger counterpart: stable events, account evidence, 15-minute buckets.

Input includes cache writes; output includes reasoning. The exclusive display
columns subtract those subsets. Totals never add cache-write/reasoning twice.
"""
import json,sqlite3,time
from pathlib import Path


class UsageLedger:
    def __init__(self,path):self.path=Path(path)
    def known_accounts(self,source):
        # Settings needs identities only, not a full token/model/time report.
        # Keep this path read-only and bounded so a sidebar refresh cannot run
        # all aggregation queries or create a database on the GUI thread.
        if not self.path.exists():return []
        db=sqlite3.connect(self.path.resolve().as_uri()+'?mode=ro',uri=True,timeout=.1)
        try:
            rows=db.execute('SELECT identity,label,evidence,observed FROM accounts WHERE source=? ORDER BY observed DESC LIMIT 100',(source,)).fetchall()
            return [dict(id=r[0],label=r[1],evidence=r[2],observed=r[3]) for r in rows]
        finally:db.close()
    def connect(self):
        self.path.parent.mkdir(parents=True,exist_ok=True)
        db=sqlite3.connect(self.path,timeout=2)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE IF NOT EXISTS events (source TEXT,event TEXT,session TEXT,model TEXT,at REAL,input INTEGER,output INTEGER,cache INTEGER,cache_write INTEGER,reasoning INTEGER,account TEXT,PRIMARY KEY(source,event))')
        db.execute('CREATE INDEX IF NOT EXISTS event_time ON events(at)')
        db.execute('CREATE TABLE IF NOT EXISTS accounts (source TEXT,identity TEXT,label TEXT,evidence TEXT,observed REAL,PRIMARY KEY(source,identity))')
        db.execute('CREATE TABLE IF NOT EXISTS event_origin(source TEXT,event TEXT,group_id TEXT,priority INTEGER,PRIMARY KEY(source,event))')
        db.execute('CREATE INDEX IF NOT EXISTS origin_group ON event_origin(source,group_id,priority)')
        return db
    def record(self,source,events,accounts=()):
        db=self.connect()
        try:
            with db:
                for event in events:
                    db.execute('INSERT OR REPLACE INTO event_origin VALUES(?,?,?,?)',(source,event['id'],event['session'],event.get('priority',0)))
                    db.execute("INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(source,event) DO UPDATE SET input=excluded.input,output=excluded.output,cache=excluded.cache,cache_write=excluded.cache_write,reasoning=excluded.reasoning,model=CASE WHEN excluded.model!='Unknown' THEN excluded.model ELSE events.model END WHERE ? OR excluded.input+excluded.output+excluded.cache>=events.input+events.output+events.cache",
                        (source,event['id'],event['session'],event.get('model','Unknown'),event['at'],event['input'],event['output'],event['cache'],event.get('cache_write',0),event.get('reasoning',0),event.get('account'),bool(event.get('correction'))))
                for account in accounts:
                    db.execute('INSERT OR REPLACE INTO accounts VALUES(?,?,?,?,?)',(source,account['id'],account.get('label','账户'),account.get('evidence','unresolved'),time.time()))
        finally:db.close()
    def report(self,source,hours=168,account=None):
        db=self.connect();since=time.time()-hours*3600
        where='source=? AND at>=?'+(' AND account=?' if account else '')+''' AND COALESCE((SELECT priority FROM event_origin o WHERE o.source=events.source AND o.event=events.event),0)>=COALESCE((SELECT MAX(priority) FROM event_origin o WHERE o.source=events.source AND o.group_id=events.session),0)'''
        params=(source,since,account) if account else (source,since)
        try:
            totals=db.execute('SELECT COALESCE(SUM(input),0),COALESCE(SUM(output),0),COALESCE(SUM(cache),0),COALESCE(SUM(cache_write),0),COALESCE(SUM(reasoning),0),COUNT(*) FROM events WHERE '+where,params).fetchone()
            buckets=db.execute('SELECT CAST(at/900 AS INTEGER)*900,SUM(input),SUM(output),SUM(cache),SUM(cache_write),SUM(reasoning) FROM events WHERE '+where+' GROUP BY 1 ORDER BY 1',params).fetchall()
            models=db.execute('SELECT model,SUM(input),SUM(output),SUM(cache),SUM(cache_write),SUM(reasoning) FROM events WHERE '+where+' GROUP BY model ORDER BY SUM(input+output+cache) DESC',params).fetchall()
            model_buckets=db.execute('SELECT CAST(at/900 AS INTEGER)*900,model,SUM(input),SUM(output),SUM(cache),SUM(cache_write),SUM(reasoning) FROM events WHERE '+where+' GROUP BY 1,2 ORDER BY 1,2',params).fetchall()
            accounts=db.execute('SELECT identity,label,evidence,observed FROM accounts WHERE source=? ORDER BY observed DESC',(source,)).fetchall()
            return dict(totals=self.counts(totals[:5]),event_count=totals[5],hours=hours,scope='account' if account else 'local',
                buckets=[dict(at=row[0],**self.counts(row[1:])) for row in buckets],
                models=[dict(model=row[0],**self.counts(row[1:])) for row in models],
                model_buckets=[dict(at=row[0],model=row[1],**self.counts(row[2:])) for row in model_buckets],
                accounts=[dict(id=r[0],label=r[1],evidence=r[2],observed=r[3]) for r in accounts])
        finally:db.close()
    @staticmethod
    def counts(values):
        inp,out,cache,write,reasoning=values
        return dict(input=inp,output=out,cache=cache,cache_write=write,reasoning=reasoning,
                    fresh_input=max(0,inp-write),visible_output=max(0,out-reasoning),total=inp+out+cache)
