import time,unittest
from datetime import datetime,timedelta
from PySide6.QtWidgets import QApplication
from stats_widgets import columns,period_totals,TokenDashboard,kind_colors


class StatsWidgets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.app=QApplication.instance() or QApplication([])
    def test_source_channels_are_exclusive_and_range_filters_do_not_double_count(self):
        now=2000000000
        stats=dict(buckets=[dict(at=now-100,fresh_input=10,cache=20,cache_write=3,visible_output=4,reasoning=2),dict(at=now-6*3600,fresh_input=40)])
        self.assertEqual(sum(row['total'] for row in columns(stats,5,now=now)),39)
        self.assertEqual(sum(row['total'] for row in columns(stats,24,now=now,bucket_seconds=3600)),79)
        self.assertEqual(sum(row['total'] for row in columns(stats,24,channels=('fresh_input',),now=now)),50)
        self.assertEqual(kind_colors(False)['cache'],'#31c3b5');self.assertEqual(kind_colors(True)['fresh_input'],'#398ad6')
    def test_recent_periods_start_today_at_local_midnight(self):
        now=time.time();today=datetime.fromtimestamp(now).replace(hour=0,minute=0,second=0,microsecond=0).timestamp()
        stats=dict(buckets=[dict(at=today+1,fresh_input=10),dict(at=today-1,fresh_input=20),dict(at=now-8*86400,fresh_input=30)])
        self.assertEqual(period_totals(stats,now=now),[10,30,60])
    def test_source_default_and_at_least_one_kind_remains_selected(self):
        widget=TokenDashboard('Codex');self.addCleanup(widget.close)
        self.assertEqual(widget.hours,24);self.assertEqual(widget.bucket.currentData(),3600);self.assertNotIn('cache',widget.channels)
        widget.set_kinds(['fresh_input']);widget.toggle('fresh_input',False);self.assertEqual(widget.channels,['fresh_input'])
        widget.range.setCurrentIndex(widget.range.findData(720));self.assertEqual(widget.hours,720);self.assertTrue(widget.bucket.isHidden())
        widget.set_kinds(['cache']);self.assertEqual(widget.channels,['cache'])

if __name__=='__main__':unittest.main()
