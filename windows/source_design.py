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
    all_palettes = (DESKTOP / 'Theme/Theme+Palettes.swift').read_text(encoding='utf-8')
    palette = all_palettes.split('static let light =')[0]
    light_palette=all_palettes.split('static let light =')[1].split('static let island:')[0]
    light_colors={key:'#'+value for key,value in re.findall(r'(\w+): Color\(hex: 0x([0-9a-fA-F]{6})\)',light_palette)}
    colors = {key: '#' + value for key, value in re.findall(r'(\w+): Color\(hex: 0x([0-9a-fA-F]{6})\)', palette)}
    levels = (DESKTOP / 'Theme/StatusPalette.swift').read_text(encoding='utf-8')
    under=(DESKTOP/'Theme/Theme+Under.swift').read_text(encoding='utf-8')
    greys={}
    for light,black,glass,fields,values in re.findall(r'case \((false|true), (false|true|_), (false|true|_)\):\s*\(([^)]+)\) = \(([^)]+)\)',under):
        names=[name.strip() for name in fields.split(',')];parts=[None if part.strip()=='nil' else float(part) for part in values.split(',')]
        entry=dict(zip(names,parts));entry.setdefault('idle',entry['secondary']);greys[','.join((light,black,glass))]=entry
    if len(greys)!=4:raise ValueError('Original SeeThroughGreys contract changed')
    status_colors={key:'#'+value for key,value in re.findall(r'static let (\w+) = RGBA\(hex: 0x([0-9a-fA-F]{6})\)',levels)}
    glass_text={key+('Light' if light=='true' else 'Dark'):'#'+value for key,light,value in re.findall(r'case \(\.(\w+), (true|false)\): return RGBA\(hex: 0x([0-9a-fA-F]{6})\)',levels)}
    colors.update({key: '#' + value for key, value in re.findall(r'static let (ok|warning|critical|idle) = RGBA\(hex: 0x([0-9a-fA-F]{6})\)', levels)})
    style = (CORE / 'PanelLayout/PanelLayout.swift').read_text(encoding='utf-8')
    placement = (CORE / 'Models/Settings/ScreenPlacement.swift').read_text(encoding='utf-8')
    simple = (DESKTOP / 'Notch/Simple/SimpleMeter.swift').read_text(encoding='utf-8')
    animation = (DESKTOP / 'Notch/Island/IslandAnimation.swift').read_text(encoding='utf-8')
    row = (DESKTOP / 'Notch/Panel/ProviderQuotaBlock.swift').read_text(encoding='utf-8')
    metric_row=(DESKTOP/'Notch/Panel/ModelUsageRow.swift').read_text(encoding='utf-8')
    geometry=(DESKTOP/'Notch/NotchGeometry.swift').read_text(encoding='utf-8')
    island=(DESKTOP/'Notch/Island/IslandRootView.swift').read_text(encoding='utf-8')
    build=(ROOT/'scripts/build-app.sh').read_text(encoding='utf-8')
    shell=(DESKTOP/'Notch/ScreenHUD.swift').read_text(encoding='utf-8')
    alerts=(DESKTOP/'Notch/Alerts/IslandAlert.swift').read_text(encoding='utf-8')
    controller=(DESKTOP/'Notch/Island/IslandController.swift').read_text(encoding='utf-8')
    return dict(colors=colors,light_colors=light_colors,status_colors=status_colors,glass_text=glass_text,see_through_greys=greys,
                alert_seconds=number(alerts,r'visibleDuration: Duration = \.seconds\((\d+)\)'),
                alert_width=number(controller,r'alertDetailWidth: CGFloat = (\d+)'),
                full_corner=number(shell,r'full \? (\d+)'),bubble_corner=number(shell,r'bubble \? (\d+)'),
                app_name=re.search(r'APP_NAME="([^"]+)"',build)[1],
                app_version=re.search(r'CFBundleShortVersionString</key><string>([^<]+)',build)[1],
                app_icon=ROOT/'assets/AppIcon.icns',width=number(style, r'defaultWidth = (\d+)'),
                peek_height=number(island,r'dockCompactHeight: CGFloat = ([\d.]+)'),
                peek_font=number(island,r'dockTextSize: CGFloat = ([\d.]+)'),
                agent_width=number(style, r'narrowestAgentWidth = (\d+)'),
                simple_size=number(placement, r'simpleSize: Double = ([\d.]+)'),
                ring_width=number(placement, r'ringWidth: Double = ([\d.]+)'),
                edge_margin=number(simple, r'edgeMargin: CGFloat = ([\d.]+)'),
                animation_ms=1000 * number(animation, r'duration: TimeInterval = ([\d.]+)'),
                label_width=number(row, r'nameWidth: CGFloat = ([\d.]+)'),
                metric_value_width=number(metric_row,r'frame\(minWidth: (\d+), alignment: \.trailing\)'),
                metric_detail_width=number(metric_row,r'frame\(width: (\d+), alignment: \.trailing\)'),
                notch_width=number(geometry,r'fallbackWidth: CGFloat = ([\d.]+)'),
                flare=number(geometry,r'collapsedTopRadius: CGFloat = ([\d.]+)'),
                notch_radius=number(geometry,r'fallbackCornerRadius: CGFloat = ([\d.]+)'),
                resources=DESKTOP / 'Resources')


DESIGN = load_design()
