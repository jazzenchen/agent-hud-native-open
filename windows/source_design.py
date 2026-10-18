"""Read the upstream SwiftUI design constants instead of maintaining another palette.

Windows drawing counterparts are named for the views they port. Fail explicitly
if upstream changes the source contract rather than silently inventing defaults.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
DESKTOP = ROOT / 'Sources/AgentHUDDesktop'
CORE = ROOT / 'Sources/AgentHUDCore'


def number(text, pattern):
    match = re.search(pattern, text)
    if not match:
        raise ValueError('Upstream design constant changed: ' + pattern)
    return float(match[1])


def load_design():
    palette = (DESKTOP / 'Theme/Theme+Palettes.swift').read_text(encoding='utf-8').split('static let light =')[0]
    colors = {key: '#' + value for key, value in re.findall(r'(\w+): Color\(hex: 0x([0-9a-fA-F]{6})\)', palette)}
    levels = (DESKTOP / 'Theme/StatusPalette.swift').read_text(encoding='utf-8')
    colors.update({key: '#' + value for key, value in re.findall(r'static let (ok|warning|critical|idle) = RGBA\(hex: 0x([0-9a-fA-F]{6})\)', levels)})
    style = (CORE / 'PanelLayout/PanelLayout.swift').read_text(encoding='utf-8')
    placement = (CORE / 'Models/Settings/ScreenPlacement.swift').read_text(encoding='utf-8')
    simple = (DESKTOP / 'Notch/Simple/SimpleMeter.swift').read_text(encoding='utf-8')
    animation = (DESKTOP / 'Notch/Island/IslandAnimation.swift').read_text(encoding='utf-8')
    row = (DESKTOP / 'Notch/Panel/ProviderQuotaBlock.swift').read_text(encoding='utf-8')
    return dict(colors=colors, width=number(style, r'defaultWidth = (\d+)'),
                agent_width=number(style, r'narrowestAgentWidth = (\d+)'),
                simple_size=number(placement, r'simpleSize: Double = ([\d.]+)'),
                ring_width=number(placement, r'ringWidth: Double = ([\d.]+)'),
                edge_margin=number(simple, r'edgeMargin: CGFloat = ([\d.]+)'),
                animation_ms=1000 * number(animation, r'duration: TimeInterval = ([\d.]+)'),
                label_width=number(row, r'nameWidth: CGFloat = ([\d.]+)'),
                resources=DESKTOP / 'Resources')


DESIGN = load_design()
