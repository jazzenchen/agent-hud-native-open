"""SimpleMeterConfig geometry, translated from the original Swift implementation."""
from math import floor


def rounded(value):return floor(value+.5)


def simple_geometry(size,edge,rings,numbers,gap,label_widths):
    horizontal=edge in ('top','bottom')
    logo=rounded(size*(.55 if rings else .68));mark=size if rings else logo
    tight=max(3,rounded(size*.18));loose=rounded(size*.45)
    leading=tight+1 if rings else loose;trailing=loose if numbers else leading
    top=tight if horizontal else tight+3
    spacing=rounded(size*.23);item_gap=rounded(size*gap*(1 if numbers or not horizontal else .7))
    column=max(label_widths,default=0);cells=[];along=leading if horizontal else top
    for label_width in label_widths:
        width=mark+(spacing+(label_width if horizontal else column) if numbers else 0)
        cells.append((along,top,width,mark) if horizontal else (leading,along,width,mark))
        along+=(width if horizontal else mark)+item_gap
    if horizontal:
        width=along-item_gap+trailing if cells else 32;height=2*top+mark
    else:
        width=leading+mark+(spacing+column if numbers else 0)+trailing
        height=along-item_gap+top if cells else 32
    return dict(width=rounded(width),height=rounded(height),cells=cells,logo=logo,mark=mark,
                leading=leading,top=top,spacing=spacing,column=column,
                corner=min(rounded(size*.73),min(width,height)/2))
