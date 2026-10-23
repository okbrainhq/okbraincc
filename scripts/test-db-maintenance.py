#!/usr/bin/env python3
"""Real retention SQL/filesystem fixtures plus fake-SSH transport tests. Never contact production."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
RUNNERS = ROOT / 'scripts/deploy/BackupAgent'
spec = importlib.util.spec_from_file_location('retention', RUNNERS / 'db-retention.py')
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
OLD = '2001-01-01 00:00:00'
NEW = '2999-01-01T00:00:00.000Z'
WEBP = b'RIFF' + (8).to_bytes(4, 'little') + b'WEBPtest'
PRIVATE = 'PRIVATE_CHAT_TEXT_MUST_SURVIVE'
SCHEMA = '''
CREATE TABLE conversations(id TEXT PRIMARY KEY,user_id TEXT,code_project_id TEXT,active_job_id TEXT,updated_at TEXT);
CREATE TABLE messages(id TEXT PRIMARY KEY,conversation_id TEXT,role TEXT,content TEXT,created_at TEXT);
CREATE TABLE chat_events(id TEXT PRIMARY KEY,conversation_id TEXT,kind TEXT,content TEXT,created_at TEXT);
CREATE TABLE tool_call_logs(id TEXT PRIMARY KEY,conversation_id TEXT,tool_call_id TEXT,tool_name TEXT,status TEXT,
  created_at TEXT,updated_at TEXT,parent_job_id TEXT,async_job_id TEXT,response TEXT);
CREATE TABLE jobs(id TEXT PRIMARY KEY,state TEXT,type TEXT,user_id TEXT);
CREATE TABLE job_events(id TEXT PRIMARY KEY,job_id TEXT,kind TEXT,payload TEXT,created_at TEXT);
CREATE TABLE conversation_tool_jobs(id TEXT PRIMARY KEY,conversation_id TEXT,job_id TEXT,tool_name TEXT,state TEXT,updated_at TEXT,output TEXT,error TEXT);
CREATE TABLE uploads(id TEXT PRIMARY KEY,user_id TEXT,filename TEXT,created_at TEXT,owner_conversation_id TEXT,
  storage_root TEXT,image_sha256 TEXT,image_bytes INTEGER,deleted_at TEXT,deletion_reason TEXT,retention_pin TEXT,job_id TEXT,origin TEXT);
CREATE TABLE documents(id TEXT PRIMARY KEY,content TEXT);
CREATE TABLE job_queue(id TEXT PRIMARY KEY,job_id TEXT,input TEXT);
'''

FAKE_SSH = r'''
import base64,json,os,pathlib,shlex,sys
root = pathlib.Path(os.environ['FIXTURE_ROOT']).resolve()
assert sys.argv[-2] == 'fixture', 'Real SSH forbidden'
args = shlex.split(sys.argv[-1])
assert args[:3] == ['python3','-u','-c']
config = json.loads(base64.b64decode(args[-1]))
assert pathlib.Path(config['database']).resolve().is_relative_to(root)
assert pathlib.Path(config['uploads']).resolve().is_relative_to(root)
source = base64.b64decode(config['engineSource']).decode()
if os.environ.get('CASE') in ('signal_engine', 'live_engine'):
    source = "import pathlib,time;pathlib.Path(" + repr(str(root/'hanging')) + ").write_text('engine');print('CC_PROGRESS fixture live output',flush=True);time.sleep(60)"
config['engineSource'] = base64.b64encode(source.encode()).decode()
bootstrap = args[3]
# Replace only the fixed systemctl constant in the transported orchestration script.
import re
encoded = re.search(r"base64.b64decode\('([^']+)'\)", bootstrap).group(1)
transport = base64.b64decode(encoded).decode().replace('SYSTEMCTL = "/bin/systemctl"', 'SYSTEMCTL = ' + repr(str(root/'bin/systemctl')))
os.execv(sys.executable,[sys.executable,'-u','-c',transport,'--remote',base64.b64encode(json.dumps(config).encode()).decode()])
'''


class RetentionFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cc-retention-')
        self.root = Path(self.temp.name).resolve()
        self.db = self.root / "brain ' ; fixture.db"
        self.uploads = self.root / "uploads ' ; literal"
        self.uploads.mkdir()
        self.conn = sqlite3.connect(self.db)
        self.conn.executescript(SCHEMA)
        self.conn.execute('PRAGMA journal_mode=WAL')
        self.conn.executemany('INSERT INTO conversations VALUES (?,?,?,?,?)', [
            ('cp','user','project',None,NEW),('normal','user',None,None,OLD),('other','other-user','other-project',None,OLD)])
        for role in ('user','assistant','summary'):
            self.conn.execute('INSERT INTO messages VALUES (?,?,?,?,?)',(role,'cp',role,PRIVATE,OLD))
        for kind in ('assistant_text','user_message','summary','thought','compaction','sources','system_message'):
            self.event(kind,'cp',kind,PRIVATE)
        self.conn.executemany('INSERT INTO jobs VALUES (?,?,?,?)',[
            ('chat','succeeded','chat','user'),('shell','succeeded','code-project-shell','user'),
            ('idle','idle','chat','user'),('unrelated-running','running','chat','user')])
        self.conn.execute('INSERT INTO job_events VALUES (?,?,?,?,?)',('chat-text','chat','output',PRIVATE,OLD))
        self.conn.execute('INSERT INTO job_events VALUES (?,?,?,?,?)',('shell-output','shell','output','TOOL OUTPUT',OLD))
        self.conn.execute('INSERT INTO job_events VALUES (?,?,?,?,?)',('shell-status','shell','status','status',OLD))
        self.conn.execute('INSERT INTO conversation_tool_jobs VALUES (?,?,?,?,?,?,?,?)',('ctj','cp','shell','run_shell_command','succeeded',OLD,'TOOL OUTPUT',None))
        self.log('cp-log','cp','run_shell_command')
        self.log('general-log','normal','run_app')
        self.conn.commit()
        self.config = dict(database=str(self.db),uploads=str(self.uploads),days=10,deleteImages=True,action='apply')

    def tearDown(self):
        self.conn.close()
        self.temp.cleanup()

    def event(self, id, cid, kind, content, date=OLD):
        self.conn.execute('INSERT INTO chat_events VALUES (?,?,?,?,?)',(id,cid,kind,content,date))

    def log(self, id, cid, name, date=OLD, call='1'):
        self.conn.execute('INSERT INTO tool_call_logs VALUES (?,?,?,?,?,?,?,?,?,?)',(id,cid,call,name,'succeeded',date,date,None,None,'LOG'))
        self.event(id+'-call',cid,'tool_call',json.dumps({'tool_name':name,'call_id':call}),date)
        self.event(id+'-result',cid,'tool_result',json.dumps({'call_id':call,'content':'TOOL RESULT'}),date)

    def image(self, owner='cp', origin='agent', date=OLD, proven=True, reference=None):
        uid, filename = str(uuid.uuid4()), str(uuid.uuid4())+'.webp'
        path = self.uploads/filename
        path.write_bytes(WEBP)
        self.conn.execute('INSERT INTO uploads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',(
            uid,'user',filename,date,owner,str(self.uploads) if proven else None,
            hashlib.sha256(WEBP).hexdigest() if proven else None,len(WEBP) if proven else None,None,None,None,None,origin))
        if reference:
            self.event(str(uuid.uuid4()),reference,'user_message',PRIVATE+' ![image](/uploads/'+filename+')')
        return uid,path

    def run_engine(self, action='apply', expected=0):
        self.conn.commit()
        runner = engine.Retention(dict(self.config,action=action))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = runner.run()
        self.assertEqual(code,expected,output.getvalue())
        self.assertNotIn(PRIVATE,output.getvalue())
        return runner.report

    def exists(self,table,id):
        return self.conn.execute('SELECT 1 FROM '+table+' WHERE id=?',(id,)).fetchone() is not None

    def test_precise_history_scope_and_all_chat_text_preserved(self):
        for name in engine.WEB_TOOLS:
            self.log(name,'normal',name,call=name)
        self.log('fresh','cp','run_shell_command',NEW)
        self.event('malformed-general','normal','tool_result','not JSON')
        self.event('malformed-cp','cp','tool_result','not JSON')
        before = self.conn.execute("SELECT * FROM messages").fetchall()
        report=self.run_engine()
        self.assertFalse(self.exists('tool_call_logs','cp-log'))
        self.assertTrue(self.exists('tool_call_logs','general-log'))
        self.assertTrue(self.exists('tool_call_logs','fresh'))
        for name in engine.WEB_TOOLS:
            self.assertFalse(self.exists('tool_call_logs',name))
            self.assertFalse(self.exists('chat_events',name+'-result'))
        self.assertTrue(self.exists('chat_events','malformed-general'))
        self.assertFalse(self.exists('chat_events','malformed-cp'))
        self.assertEqual(before,self.conn.execute('SELECT * FROM messages').fetchall())
        self.assertEqual(7,self.conn.execute('SELECT COUNT(*) FROM chat_events WHERE content=?',(PRIVATE,)).fetchone()[0])
        self.assertTrue(self.exists('job_events','chat-text'))
        self.assertFalse(self.exists('job_events','shell-output'))
        self.assertTrue(self.exists('job_events','shell-status'))
        self.assertIsNone(self.conn.execute('SELECT output FROM conversation_tool_jobs').fetchone()[0])
        self.assertEqual('optimize-passive-checkpoint',report['compaction'])
        self.assertEqual('ok',report['databaseCheck'])

    def test_old_project_images_expire_in_active_long_lived_chats(self):
        uid,path=self.image(reference='cp')
        before=self.conn.execute('SELECT content FROM chat_events WHERE kind="user_message"').fetchall()
        report=self.run_engine()
        self.assertFalse(path.exists())
        self.assertEqual(1,report['images']['deleted'])
        self.assertEqual(before,self.conn.execute('SELECT content FROM chat_events WHERE kind="user_message"').fetchall())
        self.assertEqual('code-project-retention-v3',self.conn.execute('SELECT deletion_reason FROM uploads WHERE id=?',(uid,)).fetchone()[0])

    def test_legacy_and_user_project_images_inferred_without_rewriting_text(self):
        files=[self.image(owner=None,origin=origin,proven=False,reference='cp')[1] for origin in ('user','unknown')]
        report=self.run_engine()
        self.assertTrue(all(not f.exists() for f in files))
        self.assertEqual(2,report['images']['deleted'])

    def test_ownership_is_captured_before_tool_logs_are_pruned(self):
        uid,path=self.image(owner=None,origin='unknown',proven=False)
        self.event('legacy-tool','cp','tool_result',json.dumps({'url':'/uploads/'+path.name}))
        self.run_engine()
        self.assertFalse(path.exists())

    def test_outside_references_unknown_and_nonproject_uploads_protected(self):
        files=[self.image(owner='normal')[1],self.image(owner=None,proven=False)[1],self.image(reference='normal')[1]]
        uid,doc=self.image()
        self.conn.execute('INSERT INTO documents VALUES (?,?)',('doc',f'<img src="/uploads/{doc.name}">'))
        files.append(doc)
        uid,wronguser=self.image(owner=None,proven=False,reference='other')
        files.append(wronguser)
        report=self.run_engine()
        self.assertTrue(all(f.exists() for f in files))
        self.assertEqual(0,report['images']['deleted'])

    def test_recent_pinned_and_wrong_root_protected(self):
        files=[self.image(date=NEW)[1]]
        for column,value in [('retention_pin','keep'),('storage_root','/different-root')]:
            uid,path=self.image();files.append(path)
            self.conn.execute('UPDATE uploads SET '+column+'=? WHERE id=?',(value,uid))
        self.run_engine()
        self.assertTrue(all(f.exists() for f in files))

    def test_only_linked_running_jobs_protect_project(self):
        uid,path=self.image()
        self.conn.execute('UPDATE conversations SET active_job_id="unrelated-running" WHERE id="cp"')
        self.run_engine()
        self.assertTrue(path.exists());self.assertTrue(self.exists('tool_call_logs','cp-log'))
        self.conn.execute('UPDATE jobs SET state="succeeded" WHERE id="unrelated-running"')
        self.run_engine()
        self.assertFalse(path.exists())

    def test_sweeps_more_than_300_rows_in_one_run(self):
        files=[self.image()[1] for _ in range(355)]
        report=self.run_engine()
        self.assertEqual(355,report['images']['deleted'])
        self.assertTrue(report['images']['sweepComplete'])
        self.assertTrue(all(not f.exists() for f in files))

    def test_dry_run_changes_neither_database_nor_files(self):
        uid,path=self.image()
        self.conn.commit()
        before=list(self.conn.iterdump())
        report=self.run_engine('dryRun')
        self.assertEqual(before,list(self.conn.iterdump()))
        self.assertTrue(path.exists());self.assertEqual(0,report['images']['deleted'])
        self.assertEqual(1,report['images']['candidates'])
        self.assertIsNone(report['compaction'])

    def test_vacuum_does_not_run_retention(self):
        uid,path=self.image()
        before=self.conn.execute('SELECT * FROM messages').fetchall()
        report=self.run_engine('vacuum')
        self.assertEqual('vacuum',report['compaction'])
        self.assertIsNone(report['images']);self.assertTrue(path.exists())
        self.assertTrue(self.exists('tool_call_logs','cp-log'))
        self.assertEqual(before,self.conn.execute('SELECT * FROM messages').fetchall())

    def test_missing_file_finalized_and_second_run_idempotent(self):
        uid,path=self.image();path.unlink()
        report=self.run_engine()
        self.assertEqual(1,report['images']['missingFinalized'])
        self.assertEqual(0,report['images']['deleted'])
        self.assertEqual(0,self.run_engine()['images']['examined'])

    def test_hash_symlink_hardlink_and_nonimage_fail_closed(self):
        files=[]
        for mode in ('hash','symlink','hardlink','nonimage'):
            uid,path=self.image();files.append(path)
            if mode=='hash': self.conn.execute('UPDATE uploads SET image_sha256=? WHERE id=?',('0'*64,uid))
            if mode=='symlink': path.unlink();path.symlink_to(self.db)
            if mode=='hardlink': os.link(path,self.uploads/'extra-link')
            if mode=='nonimage': path.write_bytes(b'NOT_AN_IMAGE____')
        report=self.run_engine()
        self.assertEqual(4,report['images']['errors'])
        self.assertTrue(all(f.exists() for f in files))

    def test_concurrent_reference_change_defers_without_deleting_image(self):
        uid,path=self.image()
        original=engine.Retention.history
        def change(runner,apply):
            original(runner,apply)
            with sqlite3.connect(self.db) as c:
                c.execute('INSERT INTO documents VALUES (?,?)',('new-ref','/uploads/'+path.name))
        with patch.object(engine.Retention,'history',change):
            report=self.run_engine(expected=2)
        self.assertTrue(path.exists());self.assertFalse(report['images']['sweepComplete'])
        self.assertEqual('image_snapshot_changed_retry',report['error'])
        self.assertTrue(report['partial'])
        self.assertEqual('optimize-passive-checkpoint',report['compaction'])

    def test_trigger_cannot_delete_chat_text(self):
        self.conn.execute('CREATE TRIGGER evil AFTER DELETE ON tool_call_logs BEGIN DELETE FROM messages; END')
        report=self.run_engine(expected=2)
        self.assertEqual(3,self.conn.execute('SELECT COUNT(*) FROM messages').fetchone()[0])
        self.assertTrue(self.exists('tool_call_logs','cp-log'))

    def test_utc_iso_sqlite_and_invalid_dates(self):
        self.log('old-iso','cp','read_file','2001-01-01T00:00:00.123Z')
        self.log('invalid-time','cp','read_file','invalid')
        self.run_engine()
        self.assertFalse(self.exists('tool_call_logs','old-iso'))
        self.assertTrue(self.exists('tool_call_logs','invalid-time'))

    def test_configurable_retention_applies_to_logs_and_images(self):
        date=self.conn.execute("SELECT datetime('now','-15 days')").fetchone()[0]
        uid,path=self.image(date=date)
        self.log('15-days','cp','read_file',date)
        self.config['days']=20
        self.run_engine();self.assertTrue(path.exists());self.assertTrue(self.exists('tool_call_logs','15-days'))
        self.config['days']=10
        self.run_engine();self.assertFalse(path.exists());self.assertFalse(self.exists('tool_call_logs','15-days'))

    def test_job_queue_chat_link_survives_pruned_tool_logs(self):
        uid,path=self.image(owner=None,origin='unknown',proven=False)
        self.conn.execute('INSERT INTO job_queue VALUES (?,?,?)',('q','shell',json.dumps({'conversationId':'cp','image':'/uploads/'+path.name})))
        self.conn.execute('UPDATE job_events SET payload=? WHERE id="shell-output"',('/uploads/'+path.name,))
        self.run_engine()
        self.assertFalse(path.exists())
        self.assertTrue(self.exists('job_events','chat-text'))

    def test_deeply_escaped_unrelated_content_does_not_block_images(self):
        uid,path=self.image()
        self.conn.execute('INSERT INTO documents VALUES (?,?)',('encoded','%'+'25'*20+'20'))
        self.run_engine()
        self.assertFalse(path.exists())

    def test_online_nonwal_database_fails_before_changes(self):
        self.conn.commit()
        self.conn.execute('PRAGMA journal_mode=DELETE')
        self.run_engine(expected=2)
        self.assertTrue(self.exists('tool_call_logs','cp-log'))

    def test_unconfirmed_unlink_is_reported_and_retry_finalizes(self):
        uid,path=self.image()
        original=engine.Retention.connect
        def deny_tombstone(runner,apply):
            original(runner,apply)
            authorize=runner.authorize
            runner.authorize=lambda action,table,*args: sqlite3.SQLITE_DENY if action==sqlite3.SQLITE_UPDATE and table=='uploads' else authorize(action,table,*args)
        with patch.object(engine.Retention,'connect',deny_tombstone):
            report=self.run_engine(expected=2)
        self.assertFalse(path.exists())
        self.assertTrue(report['images']['unconfirmedBatch'])
        self.assertEqual(0,report['images']['deleted'])
        self.assertEqual(1,self.run_engine()['images']['missingFinalized'])

    def test_vacuum_refuses_insufficient_space_without_retention(self):
        with patch.object(engine.shutil,'disk_usage',return_value=type('Disk',(),{'free':0})()):
            report=self.run_engine('vacuum',expected=2)
        self.assertEqual('vacuum_insufficient_free_disk_space',report['error'])
        self.assertTrue(self.exists('tool_call_logs','cp-log'))

    def test_schema_failure_before_any_mutation(self):
        self.conn.execute('ALTER TABLE uploads RENAME COLUMN deleted_at TO missing_column')
        self.run_engine(expected=2)
        self.assertTrue(self.exists('tool_call_logs','cp-log'))

    def test_web_call_keys_are_scoped_to_conversation(self):
        self.log('web','normal','internet_search',call='1')
        self.log('unrelated','other','run_app',call='1')
        self.conn.execute('UPDATE conversations SET code_project_id=NULL WHERE id="other"')
        self.run_engine()
        self.assertFalse(self.exists('chat_events','web-result'))
        self.assertTrue(self.exists('chat_events','unrelated-result'))

    def transport(self,action='apply',case=None,expected=0):
        self.conn.commit()
        bin=self.root/'bin';bin.mkdir(exist_ok=True)
        for name,source in [('ssh',FAKE_SSH),('sudo',FAKE_SUDO),('systemctl',FAKE_SYSTEMCTL)]:
            p=bin/name;p.write_text('#!'+sys.executable+'\n'+source);p.chmod(0o755)
        (self.root/'services.json').write_text(json.dumps({'brain':'active','fixture-worker':'inactive'}))
        env=dict(os.environ,FIXTURE_ROOT=str(self.root),PATH=str(bin)+os.pathsep+os.environ['PATH'])
        for k in list(env):
            if k.startswith('OKBRAINCC_DB_MAINTENANCE_'): del env[k]
        for key,value in dict(REMOTE_HOST='fixture',DATABASE=str(self.db),UPLOADS_DIRECTORY=str(self.uploads),
            WRITER_SERVICES='brain fixture-worker',DOWNTIME_ACKNOWLEDGED='1',WRITERS_ACKNOWLEDGED='1').items():
            env['OKBRAINCC_DB_MAINTENANCE_'+key]=value
        if case: env['CASE']=case
        command=['bash',str(RUNNERS/f'db-maintenance-{action}.sh')]
        if case=='live_engine':
            log=self.root/'live.log'
            with log.open('w') as capture:
                proc=subprocess.Popen(command,env=env,stdout=capture,stderr=capture,text=True)
                try:
                    for _ in range(250):
                        if 'CC_PROGRESS fixture live output' in log.read_text(): break
                        time.sleep(.02)
                    self.assertIn('CC_PROGRESS fixture live output',log.read_text())
                    self.assertNotIn('CC_RESULT ',log.read_text())
                    self.assertIsNone(proc.poll(), 'Progress must arrive BEFORE the engine exits')
                finally:
                    proc.terminate();proc.wait(timeout=15)
            out,err,code=log.read_text(),'',proc.returncode
        elif case=='signal_engine':
            proc=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            for _ in range(200):
                if (self.root/'hanging').exists():break
                time.sleep(.02)
            self.assertTrue((self.root/'hanging').exists())
            proc.terminate();out,err=proc.communicate(timeout=15);code=proc.returncode
        else:
            p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=30)
            code,out,err=p.returncode,p.stdout,p.stderr
        self.assertEqual(expected,code,out+err)
        self.assertNotIn(PRIVATE,out)
        self.assertEqual(1, out.count('CC_RESULT '), 'Only the final post-restoration report may be exposed')
        return json.loads([l[10:] for l in out.splitlines() if l.startswith('CC_RESULT ')][-1])

    def test_progress_streams_while_engine_is_still_running(self):
        self.transport('vacuum','live_engine',130)
        self.assertEqual('active',json.loads((self.root/'services.json').read_text())['brain'])
        log=(self.root/'live.log').read_text()
        self.assertLess(log.index('Writer restored and verified active:'),log.index('CC_RESULT '))

    def test_real_engine_transported_without_counterpart_scripts_or_services(self):
        uid,path=self.image()
        report=self.transport(case='missing_permissions')
        self.assertEqual(1,report['images']['deleted']);self.assertFalse(path.exists())
        self.assertFalse((self.root/'trace').exists())

    def test_manual_vacuum_restores_only_previously_active_services(self):
        self.transport('vacuum')
        self.assertEqual({'brain':'active','fixture-worker':'inactive'},json.loads((self.root/'services.json').read_text()))
        trace=(self.root/'trace').read_text()
        self.assertIn('"stop", "brain"',trace);self.assertIn('"start", "brain"',trace)
        self.assertNotIn('"start", "fixture-worker"',trace)

    def test_stop_failure_still_restores_service(self):
        self.transport('vacuum','stop_fail',2)
        self.assertEqual('active',json.loads((self.root/'services.json').read_text())['brain'])

    def test_restart_failure_is_visible(self):
        report=self.transport('vacuum','restart_fail',4)
        self.assertTrue(report['restorationFailed'])

    def test_cancel_vacuum_restores_services(self):
        self.transport('vacuum','signal_engine',130)
        self.assertEqual('active',json.loads((self.root/'services.json').read_text())['brain'])

    def test_cancel_online_does_not_stop_services(self):
        self.transport('apply','signal_engine',130)
        self.assertFalse((self.root/'trace').exists())


# Service doubles are appended below; no live command may be invoked by these fixtures.
FAKE_SUDO = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
with (root / "trace").open("a") as f: f.write(json.dumps(["sudo"] + sys.argv[1:]) + "\n")
if os.environ.get("CASE") == "missing_permissions": sys.exit(77)
expected = str(pathlib.Path(os.environ["FIXTURE_ROOT"]) / "bin/systemctl")
assert sys.argv[1] == "-n" and sys.argv[2] == expected, "REFUSING real sudo"
os.execv(expected, [expected] + sys.argv[3:])
'''

FAKE_SYSTEMCTL = r'''
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
assert args[0] in ("show", "start", "stop")
service = args[-1]
assert service in ("brain", "fixture-worker"), "Only explicitly configured fixture services allowed"
with (root / "trace").open("a") as f: f.write(json.dumps(["systemctl"] + args) + "\n")
if os.environ.get("CASE") == "missing_permissions": sys.exit(77)
state_path = root / "services.json"
states = json.loads(state_path.read_text())
case = os.environ.get("CASE")
if args[0] == "show":
    print("LoadState=" + ("not-found" if case == "unknown_service" else "loaded"))
    print("ActiveState=" + states[service])
else:
    if args[0] == "stop":
        if case != "stop_lies": states[service] = "inactive"
        state_path.write_text(json.dumps(states))
        if case == "stop_fail": sys.exit(1)
        if case == "signal_stop":
            (root / "hanging").write_text("stop")
            time.sleep(60)
    else:
        if case == "restart_fail": sys.exit(1)
        states[service] = "active"
        state_path.write_text(json.dumps(states))
'''

if __name__ == '__main__':
    unittest.main(verbosity=2)
