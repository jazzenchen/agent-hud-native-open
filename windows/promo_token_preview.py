"""Render actual TokenDashboard samples. Use QT_QPA_PLATFORM=windows for fonts."""
import argparse
import json
import time
from pathlib import Path
from PySide6.QtWidgets import QApplication, QWidget, QVBoxLayout, QLabel
from promo_fixtures import build_demo
from stats_widgets import TokenDashboard
from theme import apply_widget_theme


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    app=QApplication([]);app.setStyle('Fusion')
    fixture=build_demo(time.time(),20)
    window=QWidget();window.setAutoFillBackground(True)
    layout=QVBoxLayout(window);layout.setContentsMargins(24,20,24,20)
    disclosure=QLabel(fixture['disclosure']);layout.addWidget(disclosure)
    dashboard=TokenDashboard('Codex');layout.addWidget(dashboard)
    window.resize(840,860)
    for vendor,reading in fixture['providers'].items():
        dashboard.client=vendor
        dashboard.set_data(reading['local']['stats'])
        for light in (False,True):
            apply_widget_theme(window,light);window.show();app.processEvents()
            window.grab().save(str(args.output/(vendor.lower()+('-light' if light else '-dark')+'.png')))
    (args.output/'demo-input.json').write_text(json.dumps(fixture,ensure_ascii=False,indent=2),encoding='utf-8')
    window.close()
    print(json.dumps(dict(output=str(args.output),vendors=list(fixture['providers']),demo=True)))


if __name__=='__main__':main()
