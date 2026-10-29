import json,unittest
from pathlib import Path
from panel_plan import plan,cell_width,columns_fitting,NARROWEST_CELL,NARROWEST_HALF,grid_geometry


class PanelPlanContract(unittest.TestCase):
    def contract(self):return json.loads((Path(__file__).parent/'assets/upstream-plan-contract.json').read_text(encoding='utf-8'))
    def test_all_compiled_original_layout_plans(self):
        reference=self.contract();self.assertEqual(len(reference['cases']),144)
        for index,case in enumerate(reference['cases']):
            with self.subTest(index=index,layout=case['layout'],width=case['contentWidth'],pairs=case['pairs']):
                got=plan(case['layout'],reference['blocks'],case['contentWidth'],case['pairs'])
                self.assertEqual(got,{key:case[key] for key in ('halvesFit','sections','lines')})
    def test_original_compiled_column_widths_and_fitting_limits(self):
        reference=self.contract();self.assertAlmostEqual(NARROWEST_CELL,reference['narrowestCell'],places=12)
        self.assertAlmostEqual(NARROWEST_HALF,reference['narrowestHalf'],places=12)
        for case in reference['grids']:
            self.assertAlmostEqual(cell_width(case['width'],case['columns']),case['cellWidth'],places=12)
            self.assertEqual(columns_fitting(case['width']),case['fittingColumns'])
    def test_partial_last_line_is_centred_but_single_line_shares_available_width(self):
        cells,height=grid_geometry([80,80,80],404,2)
        self.assertEqual(cells[0]['width'],cells[2]['width']);self.assertAlmostEqual(cells[2]['x']+cells[2]['width']/2,202)
        self.assertEqual(height,174)
        cells,_=grid_geometry([80],404,6);self.assertEqual(cells[0]['width'],392)
        self.assertEqual(cells[0]['x'],6)
    def test_empty_grid_is_bounded(self):
        cells,height=grid_geometry([],404,4);self.assertEqual(cells,[]);self.assertEqual(height,4)


if __name__=='__main__':unittest.main()
