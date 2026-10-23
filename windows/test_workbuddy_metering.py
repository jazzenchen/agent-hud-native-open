import json,sqlite3,tempfile,unittest
from contextlib import closing
from pathlib import Path
from workbuddy_metering import read,entry_models


class WorkBuddyMetering(unittest.TestCase):
    def fixture(self,directory):
        path=Path(directory)/'workbuddy.db'
        with closing(sqlite3.connect(path)) as db,db:
            db.execute('CREATE TABLE sessions(id TEXT,custom_title TEXT,title TEXT)')
            db.execute('CREATE TABLE session_usage(session_id TEXT,used INTEGER,size INTEGER,credit_json TEXT)')
            db.executemany('INSERT INTO sessions VALUES(?,?,?)',[('a','Renamed in app','Generated'),('b',None,'Other'),('unreported','Private older session','Old')])
            db.executemany('INSERT INTO session_usage VALUES(?,?,?,?)',[('a',100,1000,json.dumps(dict(shared=2,unique=3))),('b',200,1000,json.dumps(dict(shared=4))),('unreported',1,1,'{"private":999}')])
        return path

    def test_read_only_report_scope_title_precedence_context_and_unattributed_credit(self):
        with tempfile.TemporaryDirectory() as directory:
            path=self.fixture(directory);before=path.read_bytes()
            titles,credits=read(path,[dict(id='a'),dict(id='b')],dict(a={'model-a'},b={'model-b'}))
            self.assertEqual(titles,dict(a='Renamed in app',b='Other'))
            self.assertEqual(credits['a'],dict(total=5,unattributed=2,byModel={'workbuddy-model:model-a':3},used=100,size=1000))
            self.assertEqual(credits['b']['unattributed'],4)
            self.assertEqual(before,path.read_bytes());self.assertNotIn('unreported',credits)
            self.assertFalse(read(path,[dict(id='a')],{})[1])
            with closing(sqlite3.connect(path)) as db,db:db.execute("UPDATE sessions SET custom_title='Renamed again' WHERE id='a'")
            self.assertEqual(read(path,[dict(id='a')],{})[0]['a'],'Renamed again')

    def test_intersection_requires_one_model_and_invalid_metering_never_becomes_balance(self):
        self.assertEqual(entry_models(dict(a={'x':1},b={'x':2}),dict(a={'one','two'},b={'two'})),{'x':'two'})
        with tempfile.TemporaryDirectory() as directory:
            path=self.fixture(directory)
            for invalid in ('{"bad":NaN}','{"bad":-1}','[]','{"bad":true}'):
                with closing(sqlite3.connect(path)) as db,db:db.execute('UPDATE session_usage SET credit_json=? WHERE session_id=?',(invalid,'a'))
                self.assertFalse(read(path,[dict(id='a')],dict(a={'one'}))[1])
            self.assertFalse(read(Path(directory)/'missing.db',[dict(id='a')],{})[0])
            self.assertFalse((Path(directory)/'missing.db').exists())

    def test_live_reader_refreshes_metering_titles_without_reparsing_transcripts(self):
        from local_sources import LocalSource
        from usage_ledger import UsageLedger
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);root=home/'.workbuddy';projects=root/'projects/demo';projects.mkdir(parents=True)
            database=self.fixture(root)
            event=dict(type='message',role='assistant',status='completed',timestamp='2026-10-19T01:00:00Z',providerData=dict(model='model-a',messageId='m',usage=dict(input_tokens=12,output_tokens=3,total_tokens=15)))
            (projects/'a.jsonl').write_text(json.dumps(event)+'\n')
            source=LocalSource('WorkBuddy',home=home,env={},ledger=UsageLedger(home/'private-test-ledger.sqlite'))
            row=source.sessions()['sessions'][0]
            self.assertEqual(row['title'],'Renamed in app');self.assertEqual(row['credits']['total'],5)
            with closing(sqlite3.connect(database)) as db,db:db.execute("UPDATE sessions SET custom_title='Without a transcript change' WHERE id='a'")
            self.assertEqual(source.sessions()['sessions'][0]['title'],'Without a transcript change')


if __name__=='__main__':unittest.main()
