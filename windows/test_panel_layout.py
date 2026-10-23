import errno,json,unittest
from pathlib import Path
from panel_layout import LayoutStore,PanelHolds,normalize,arrange_agents,switches


class PanelLayoutContract(unittest.TestCase):
    def contract(self):return json.loads((Path(__file__).parent/'assets/upstream-layout-contract.json').read_text(encoding='utf-8'))
    def test_original_compiled_normalization_cases_and_idempotence(self):
        data=self.contract();self.assertEqual(data['upstreamRevision'],'bf19ac98da11fe0f5967f5a124d42f0da4bf2cf9')
        for row in data['normalization']:
            with self.subTest(input=row['input']):
                self.assertEqual(normalize(row['input']),row['normalized'])
                self.assertEqual(normalize(normalize(row['input'])),row['normalized'])

    def test_original_compiled_shared_screen_save_discard_and_revert_trace(self):
        store=LayoutStore();traces=[]
        def capture(name):
            traces.append(dict(step=name,revision=store.revision,shared=store.effective(),A=store.effective('A'),B=store.effective('B'),
                usesSharedA=store.uses_shared('A'),draftA=store.has_draft('A'),draftB=store.has_draft('B'),persisted=store.persisted()))
        capture('initial')
        store.propose({'style':{'width':640}});capture('propose-shared')
        store.propose({'style':{'width':640}});capture('same-proposal')
        store.propose({'tokens':{'period':'week'}},'A');capture('propose-own-A')
        store.save_panel('B');capture('save-shared-on-B')
        store.save_panel('A');capture('save-own-A')
        store.propose({});store.propose('shared','A');capture('draft-shared-and-share-A')
        store.save_panel('A');capture('save-share-A-leaves-shared-draft')
        store.discard_panel('B');capture('discard-shared-on-B')
        store.revert('A');capture('revert-A');store.revert('A');capture('revert-A-again')
        store.revert();capture('revert-shared');store.reset();capture('reset-default-keeps-previous')
        self.assertEqual(traces,self.contract()['trace'])

    def test_write_failure_keeps_saved_state_revision_and_draft_then_retry(self):
        writes=[]
        def fail(value):raise OSError(errno.ENOSPC,'Full disk')
        store=LayoutStore(writer=fail);store.propose({'style':{'width':640}});revision=store.revision
        with self.assertRaises(OSError):store.save_panel('A')
        self.assertEqual(store.revision,revision);self.assertEqual(store.current,{})
        self.assertEqual(store.draft,{'style':{'width':640}});self.assertIsNone(store.persisted())
        store.writer=writes.append;store.save_panel('A')
        self.assertFalse(store.has_draft('A'));self.assertEqual(writes,[store.persisted()])
        loaded=LayoutStore(writes[-1]);self.assertEqual(loaded.effective(),store.effective());self.assertIsNone(loaded.draft)

    def test_drafts_cannot_mutate_account_data_or_persist_and_readings_are_defensive(self):
        writes=[];store=LayoutStore(writer=writes.append)
        input={'blocks':{'away-agent':{'hiddenRows':['unknown-row']}}}
        store.propose(input,'detached-screen');input['blocks'].clear()
        snapshot=store.effective('detached-screen');snapshot['blocks'].clear()
        self.assertIn('away-agent',store.effective('detached-screen')['blocks']);self.assertEqual(writes,[])
        self.assertIsNone(store.persisted());store.save('detached-screen')
        root=store.persisted();self.assertNotIn('draft',repr(root))
        store.propose({},'detached-screen')
        self.assertEqual(LayoutStore(root).effective('detached-screen'),root['screens']['detached-screen']['current'])

    def test_corruption_isolated_by_side_screen_and_field(self):
        store=LayoutStore({'shared':{'current':17,'previous':{'countdown':False}},'screens':{
            'bad':'wrong','':'ignored','A':{'current':{'style':{'width':680}},'previous':False},
            'B':{'current':None,'previous':'shared'},'C':{'current':False}}})
        self.assertEqual(store.current,{});self.assertEqual(store.previous,{'countdown':False})
        self.assertEqual(store.own('A'),{'style':{'width':680}});self.assertFalse(store.can_revert('A'))
        self.assertTrue(store.can_revert('B'));self.assertEqual(set(store.screens),{'A','B'})

    def test_person_switch_rebases_only_changed_field_without_new_previous_version(self):
        store=LayoutStore();store.propose({'tokens':{'period':'week'},'hiddenSections':['sessions']});store.save()
        store.propose({'style':{'width':680},'hiddenSections':['sessions','tokens']})
        previous=store.previous;store.set_switches({'panel_sessions':True},'A')
        self.assertEqual(store.previous,previous)
        self.assertTrue(switches(store.current)['panel_sessions']);self.assertTrue(switches(store.draft)['panel_sessions'])
        self.assertFalse(switches(store.draft)['panel_tokens']);self.assertEqual(store.draft['style']['width'],680)
        # A screen drafting its own layout still edits the saved shared layout's
        # switches, leaving that independent screen proposal intact.
        store.propose({'countdown':False},'A');store.set_switches({'panel_quota':False},'A')
        self.assertFalse(switches(store.current)['panel_quota']);self.assertEqual(store.effective('A'),{'countdown':False})

    def test_alias_first_name_and_unavailable_only_hud_fallback(self):
        self.assertEqual(arrange_agents(['ChatGPT','Claude'],['Cursor','Codex','Claude']),['Codex','Claude'])
        self.assertEqual(arrange_agents(['Unknown'],['Cursor','Codex']),['Cursor','Codex'])
        self.assertEqual(normalize({'hud':{'agents':['Grok CLI','Grok','Qoder CLI','Qoder CN']}})['hud']['agents'],['Grok CLI','Qoder CLI','Qoder CN'])
        self.assertEqual(normalize({'style':{'width':640.0},'sessions':{'limit':True}}),{'style':{'width':640}})
        self.assertEqual(normalize({'style':{'width':10**1000}}),{})
        for value in (None,[],True,2,'shared'):
            with self.assertRaises(ValueError):normalize(value)

    def test_holds_pause_renew_expire_and_scope_decisions_are_memory_only(self):
        now=[100.];store=LayoutStore();holds=PanelHolds(lambda:now[0]);store.holds=holds
        store.propose({'countdown':False},'A');store.save('A');revision=store.revision
        holds.hold('A','Codex');holds.hold('B','Claude');holds.pause('A')
        now[0]=150.;self.assertTrue(holds.get('A')['paused']);self.assertEqual(holds.remaining('A'),70)
        holds.hold('A');self.assertFalse(holds.get('A')['paused']);self.assertEqual(holds.get('A')['agent'],'Codex')
        self.assertEqual(store.revision,revision)
        store.propose({'style':{'width':640}});store.save()
        self.assertIsNone(holds.get('B'));self.assertIsNotNone(holds.get('A'))
        now[0]=270.;holds.expire();self.assertEqual(holds.screens,[])

    def test_screen_named_shared_cannot_accidentally_save_shared_draft(self):
        store=LayoutStore();store.propose({'countdown':False});store.propose({'style':{'width':680}},'shared')
        store.save_panel('shared')
        self.assertEqual(store.current,{});self.assertEqual(store.draft,{'countdown':False})
        self.assertEqual(store.own('shared'),{'style':{'width':680}})

    def test_scalar_person_edit_changes_saved_and_draft_without_touching_other_fields(self):
        store=LayoutStore();store.propose({'tokens':{'period':'week'}});store.save()
        store.propose({'style':{'width':680},'tokens':{'period':'month'}})
        before=store.previous;store.edit_field('session_limit',10)
        self.assertEqual(store.previous,before);self.assertEqual(store.draft['tokens']['period'],'month')
        self.assertEqual(store.current['tokens']['period'],'week');self.assertEqual(store.draft['sessions']['limit'],10)


if __name__=='__main__':unittest.main()
