import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from panel_charts import series


class PanelCharts(unittest.TestCase):
    def test_real_periods_exclude_future_records_and_do_not_relabel_history(self):
        now=1792400000;panel=SimpleNamespace()
        buckets=[dict(at=now-age,fresh_input=amount,total=amount) for age,amount in ((100,10),(2*86400,20),(20*86400,30),(-100,1000))]
        stats=dict(buckets=buckets,model_buckets=[dict(row,model='actual-model') for row in buckets],event_count=4,scope='local')
        data={'local':{'history_stats':stats}}
        with patch('panel_charts.time.time',return_value=now):
            self.assertEqual(series(panel,'Codex',data,'day')['total'],10)
            self.assertEqual(series(panel,'Codex',data,'week')['total'],30)
            month=series(panel,'Codex',data,'month');self.assertEqual(month['total'],60)
            self.assertEqual(month['models'],['actual-model']);self.assertEqual(stats['scope'],'local')
            self.assertIs(month,series(panel,'Codex',data,'month'))
            updated={**stats,'buckets':[],'model_buckets':[],'event_count':0}
            self.assertFalse(series(panel,'Codex',{'local':{'history_stats':updated}},'month')['reported'])


if __name__=='__main__':unittest.main()
