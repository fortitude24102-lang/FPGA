from pathlib import Path
import sys

from docx import Document
from docx.table import Table
from docx.text.paragraph import Paragraph


def iter_blocks(document):
    body = document.element.body
    for child in body.iterchildren():
        if child.tag.endswith("}p"):
            yield Paragraph(child, document)
        elif child.tag.endswith("}tbl"):
            yield Table(child, document)


def main():
    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    document = Document(source)
    lines = []
    table_index = 0
    for block in iter_blocks(document):
        if isinstance(block, Paragraph):
            text = block.text.strip()
            if text:
                lines.append(f"[P:{block.style.name}] {text}")
        else:
            table_index += 1
            lines.append(f"[TABLE {table_index}] rows={len(block.rows)} cols={len(block.columns)}")
            for row_index, row in enumerate(block.rows, start=1):
                cells = [cell.text.strip().replace("\n", " / ") for cell in row.cells]
                lines.append(f"  R{row_index}: " + " | ".join(cells))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
