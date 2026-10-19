import unittest
from promo_fixtures import build_demo, VENDORS
from usage_display import CHANNELS


class PromoFixtures(unittest.TestCase):
    def test_one_dataset_drives_sessions_models_and_exclusive_chart_totals(self):
        data=build_demo(1800000000, 20)
        self.assertTrue(data['demo']);self.assertIn('Demo',data['disclosure'])
        self.assertEqual(tuple(data['providers']),VENDORS)
        for provider in data['providers'].values():
            stats=provider['local']['stats'];total=stats['totals']['total']
            self.assertEqual(total,sum(row['tokens'] for row in provider['local']['sessions']))
            self.assertEqual(total,sum(row['total'] for row in stats['model_buckets']))
            self.assertEqual(total,sum(row['total'] for row in stats['models']))
            self.assertEqual(total,sum(stats['totals'][key] for key in CHANNELS))
            self.assertEqual(stats['scope'],'demo')
            self.assertTrue(provider['quota']['account']['id'].startswith('demo-'))

    def test_recording_clock_is_deterministic_and_only_latest_bucket_grows(self):
        now=1800000000;start=build_demo(now);end=build_demo(now,45)
        self.assertEqual(start,build_demo(now))
        for name in VENDORS:
            a=start['providers'][name]['local'];b=end['providers'][name]['local']
            self.assertEqual(a['stats']['buckets'][:-1],b['stats']['buckets'][:-1])
            self.assertLess(a['stats']['totals']['total'],b['stats']['totals']['total'])
            self.assertLess(a['sessions'][0]['tokens'],b['sessions'][0]['tokens'])
        self.assertEqual(end,build_demo(now,100))
        with self.assertRaises(ValueError):build_demo(now,float('nan'))


if __name__=='__main__':unittest.main()
