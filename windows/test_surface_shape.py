import unittest
from PySide6.QtCore import QRectF,QPointF
from PySide6.QtGui import QPainterPath
from surface_shape import surface_path


class SurfaceShape(unittest.TestCase):
    def test_capsules_stay_circular_and_rectangles_stay_bounded(self):
        rect=QRectF(12,20,180,26);circle=QPainterPath();circle.addRoundedRect(rect,13,13)
        self.assertEqual(surface_path(rect,13),circle)
        for width,height,radius in ((440,276,16),(4,4,16),(100,1,0),(24,40,9)):
            rect=QRectF(12,20,width,height);path=surface_path(rect,radius)
            self.assertEqual(path.boundingRect(),rect)
            self.assertTrue(path.contains(rect.center()))
        self.assertTrue(surface_path(QRectF(),10).isEmpty())

    def test_smooth_panel_has_matching_midcorner_derivatives_and_flat_edge_tangent(self):
        # Inspect actual cubic controls rather than a screenshot-only assertion.
        path=surface_path(QRectF(0,0,440,276),16)
        elements=[path.elementAt(i) for i in range(path.elementCount())]
        points=[QPointF(e.x,e.y) for e in elements]
        start,c1,c2,join,d1,d2,end=points[1:8]
        def close(a,b):self.assertAlmostEqual(a.x(),b.x(),places=9);self.assertAlmostEqual(a.y(),b.y(),places=9)
        close(join-c2,d1-join)
        close(join-c2*2+c1,d2-d1*2+join)
        self.assertEqual(start.y(),c1.y());self.assertEqual(start.y(),c2.y())
        self.assertEqual(end.x(),d1.x());self.assertEqual(end.x(),d2.x())


if __name__=='__main__':unittest.main()
