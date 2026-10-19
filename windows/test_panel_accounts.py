import unittest
from copy import deepcopy
from panel_accounts import sections,wallet_labels,reading_label


class PanelAccounts(unittest.TestCase):
    def test_distinct_account_ids_keep_first_row_order_and_do_not_inherit_another_plan(self):
        quota=dict(account=dict(id='current',label='Same name'),accounts=[dict(id='old',label='Same name',is_current=False,observed_at=100)],
                   plan='Current plan',at=200,credit_balance={'remaining':50},
                   windows=[dict(id='one',account_id='old'),dict(id='two',account_id='current'),dict(id='three',account_id='old')],
                   wallets=[dict(account_id='old',balance=0,currency='USD')])
        original=deepcopy(quota);groups=sections(quota)
        self.assertEqual([group['id'] for group in groups],['old','current'])
        self.assertFalse(groups[0]['is_current']);self.assertIsNone(groups[0]['quota']['plan']);self.assertEqual(groups[0]['quota']['at'],100)
        self.assertEqual([row['id'] for row in groups[0]['quota']['windows']],['one','three'])
        self.assertIsNone(groups[0]['quota']['credit_balance']);self.assertEqual(groups[0]['quota']['wallets'][0]['balance'],0)
        self.assertEqual(groups[1]['quota']['plan'],'Current plan');self.assertEqual(groups[1]['quota']['credit_balance']['remaining'],50)
        self.assertEqual(quota,original)

    def test_anonymous_rows_remain_anonymous_and_embedded_observation_wins(self):
        self.assertIsNone(sections(dict(windows=[{'label':'5h'}]))[0]['account'])
        group=sections(dict(windows=[dict(account=dict(id='a',label='Observed account',is_current=False))]))[0]
        self.assertEqual(group['id'],'a');self.assertFalse(group['is_current'])
        self.assertEqual(group['account']['label'],'Observed account')

    def test_wallet_zero_is_not_unknown_and_an_absent_limit_is_not_unlimited(self):
        self.assertEqual(wallet_labels(dict(currency='USD',balance=0)),('预付余额','$0.00'))
        self.assertEqual(wallet_labels(dict(currency='CNY',kind='onDemand',used=0)),('按需付费','已用 ¥0.00 · 上限 N/A'))
        self.assertEqual(wallet_labels(dict(currency='USD',balance=100.25)),('预付余额','$100.25'))

    def test_retained_or_failed_account_header_uses_original_rough_read_age(self):
        group=dict(is_current=False,account={},quota={'at':1000})
        self.assertEqual(reading_label(group,4600),'上次读取 1h 前')
        self.assertEqual(reading_label(group,4660),'上次读取 1h 01m 前')
        group['is_current']=True;self.assertEqual(reading_label(group,4660),'当前账户')
        group['quota']['stale']=True;self.assertEqual(reading_label(group,4660),'上次读取 1h 01m 前')


if __name__=='__main__':unittest.main()
