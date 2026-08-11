"""Minimal, repository-local DOCX table geometry helpers."""

from __future__ import annotations

from collections.abc import Sequence

from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Twips


CELL_MARGINS_DXA = {"top": 80, "bottom": 80, "start": 120, "end": 120}


def _length_to_dxa(length) -> int:
    return int(round(length.twips))


def section_content_width_dxa(section) -> int:
    """Return page width minus the section's left and right margins."""

    return (
        _length_to_dxa(section.page_width)
        - _length_to_dxa(section.left_margin)
        - _length_to_dxa(section.right_margin)
    )


def column_widths_from_weights(
    weights: Sequence[float], total_width_dxa: int
) -> list[int]:
    """Scale positive weights into integer widths with an exact total."""

    if not weights or any(weight <= 0 for weight in weights):
        raise ValueError("column weights must be non-empty and positive")
    weight_total = float(sum(weights))
    widths = [
        int(round(total_width_dxa * weight / weight_total)) for weight in weights
    ]
    widths[-1] += total_width_dxa - sum(widths)
    if any(width <= 0 for width in widths):
        raise ValueError(f"invalid computed widths: {widths}")
    return widths


def _ensure_child(parent, tag: str):
    child = parent.find(qn(tag))
    if child is None:
        child = OxmlElement(tag)
        parent.append(child)
    return child


def _set_width(parent, tag: str, width_dxa: int) -> None:
    width = _ensure_child(parent, tag)
    width.set(qn("w:type"), "dxa")
    width.set(qn("w:w"), str(int(width_dxa)))


def apply_table_geometry(table, column_widths_dxa: Sequence[int]) -> None:
    """Synchronize table, grid, column and cell widths in Word DXA units."""

    widths = [int(width) for width in column_widths_dxa]
    if not widths or any(width <= 0 for width in widths):
        raise ValueError("column widths must be non-empty and positive")

    table.autofit = False
    table.alignment = WD_TABLE_ALIGNMENT.LEFT
    table_properties = table._tbl.tblPr
    _set_width(table_properties, "w:tblW", sum(widths))

    indent = _ensure_child(table_properties, "w:tblInd")
    indent.set(qn("w:type"), "dxa")
    indent.set(qn("w:w"), str(CELL_MARGINS_DXA["start"]))
    layout = _ensure_child(table_properties, "w:tblLayout")
    layout.set(qn("w:type"), "fixed")

    grid = table._tbl.tblGrid
    for child in list(grid):
        grid.remove(child)
    for width in widths:
        grid_column = OxmlElement("w:gridCol")
        grid_column.set(qn("w:w"), str(width))
        grid.append(grid_column)

    for column_index, width in enumerate(widths):
        table.columns[column_index].width = Twips(width)

    for row in table.rows:
        if len(row.cells) != len(widths):
            raise ValueError("table geometry helper does not support merged rows")
        for column_index, cell in enumerate(row.cells):
            width = widths[column_index]
            cell.width = Twips(width)
            cell_properties = cell._tc.get_or_add_tcPr()
            _set_width(cell_properties, "w:tcW", width)
            margins = _ensure_child(cell_properties, "w:tcMar")
            for side, margin_width in CELL_MARGINS_DXA.items():
                margin = _ensure_child(margins, f"w:{side}")
                margin.set(qn("w:w"), str(margin_width))
                margin.set(qn("w:type"), "dxa")
