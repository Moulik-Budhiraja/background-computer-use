"""Shared paths, context and checker helpers."""
import csv
import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

HOME = Path.home()
EVAL_ROOT = HOME / "bcu-eval"
REPO_EVALS = Path(__file__).resolve().parent.parent
WEB_STATE = EVAL_ROOT / "web-state"
BCU = "/Applications/Background Computer Use.app/Contents/MacOS/bcu"
BCU_LOG = HOME / "Library/Application Support/BackgroundComputerUse/logs/bcu.log"


@dataclass
class Ctx:
    lane: str = "a"

    @property
    def port(self):
        return 8765 if self.lane == "a" else 8766

    @property
    def work(self) -> Path:
        return EVAL_ROOT / ("work" if self.lane == "a" else f"work-{self.lane}")

    @property
    def url(self):
        return f"http://localhost:{self.port}"

    @property
    def data_dir(self) -> Path:
        return WEB_STATE / f"data-{self.port}"

    @property
    def kv_dir(self) -> Path:
        return WEB_STATE / f"kv-{self.port}"

    @property
    def web_log(self) -> Path:
        return WEB_STATE / f"port-{self.port}.jsonl"

    def reset(self):
        if self.work.exists():
            shutil.rmtree(self.work)
        self.work.mkdir(parents=True)
        for d in (self.data_dir, self.kv_dir):
            if d.exists():
                shutil.rmtree(d)
            d.mkdir(parents=True)
        if self.web_log.exists():
            self.web_log.unlink()

    def web_events(self, kind=None):
        if not self.web_log.exists():
            return []
        out = []
        for line in self.web_log.read_text().splitlines():
            try:
                e = json.loads(line)
            except Exception:
                continue
            if kind is None or e.get("kind") == kind:
                out.append(e)
        return out

    def submissions(self, form):
        return [e["data"] for e in self.web_events("submit") if e.get("form") == form]


@dataclass
class Result:
    subgoals: dict = field(default_factory=dict)  # name -> bool
    notes: list = field(default_factory=list)
    answer: Optional[str] = None
    said_infeasible: bool = False

    @property
    def score(self):
        if not self.subgoals:
            return 0.0
        return sum(1 for v in self.subgoals.values() if v) / len(self.subgoals)

    @property
    def passed(self):
        return bool(self.subgoals) and all(self.subgoals.values())

    def to_dict(self):
        return {"passed": self.passed, "score": round(self.score, 3), "subgoals": self.subgoals,
                "notes": self.notes, "answer": self.answer, "said_infeasible": self.said_infeasible}


# ---------- final message parsing ----------
_MD = re.compile(r"[*_`]+")


def _lines(text):
    return [_MD.sub("", l).strip() for l in (text or "").splitlines()]


def extract_answer(text):
    ans = None
    for l in _lines(text):
        m = re.match(r"^(?:final\s+)?answer\s*:\s*(.+)$", l, re.I)
        if m:
            ans = m.group(1).strip()
    return ans


def said_infeasible(text):
    return any(re.match(r"^infeasible\s*:", l, re.I) for l in _lines(text))


def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip().strip(".").lower())


def num(s):
    if s is None:
        return None
    m = re.search(r"-?\d[\d,]*\.?\d*", str(s).replace("$", ""))
    if not m:
        return None
    try:
        return round(float(m.group(0).replace(",", "")), 6)
    except ValueError:
        return None


# ---------- file helpers ----------
def sha256(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def textutil(p, fmt="txt"):
    r = subprocess.run(["textutil", "-convert", fmt, "-stdout", str(p)], capture_output=True, text=True, timeout=30)
    return r.stdout


def finder_tags(p):
    r = subprocess.run(["xattr", "-px", "com.apple.metadata:_kMDItemUserTags", str(p)], capture_output=True, text=True)
    if r.returncode != 0:
        return []
    try:
        data = bytes.fromhex(r.stdout.replace(" ", "").replace("\n", ""))
        return [t.split("\n")[0] for t in plistlib.loads(data)]
    except Exception:
        return []


def set_finder_tags(p, tags):
    data = plistlib.dumps([f"{t}\n{ {'Red': 6, 'Orange': 7, 'Yellow': 5, 'Green': 2, 'Blue': 4, 'Purple': 3, 'Gray': 1}.get(t, 0)}" for t in tags],
                          fmt=plistlib.FMT_BINARY)
    subprocess.run(["xattr", "-wx", "com.apple.metadata:_kMDItemUserTags", data.hex(), str(p)], check=True)


def numbers_tables(p):
    """All tables in a .numbers file as lists of rows (values)."""
    from numbers_parser import Document
    doc = Document(str(p))
    out = []
    for sh in doc.sheets:
        for t in sh.tables:
            rows = []
            for r in t.rows(values_only=True):
                rows.append([("" if v is None else v) for v in r])
            out.append(rows)
    return out


def csv_rows(p):
    raw = Path(p).read_bytes().decode("utf-8-sig", errors="replace")
    return [r for r in csv.reader(io.StringIO(raw))]


def cell_str(v):
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def find_header_table(tables, required):
    """First table with a row containing all `required` header names (case-insensitive).
    Returns (header_index_map, data_rows) or (None, None)."""
    req = [r.lower() for r in required]
    for rows in tables:
        for i, row in enumerate(rows[:5]):
            cells = [cell_str(c).lower() for c in row]
            if all(any(c == r or c.startswith(r) for c in cells) for r in req):
                idx = {}
                for r in req:
                    for j, c in enumerate(cells):
                        if c == r or c.startswith(r):
                            idx[r] = j
                            break
                data = [row2 for row2 in rows[i + 1:] if any(cell_str(c) for c in row2)]
                return idx, data
    return None, None


def pptx_slide_texts(p):
    from pptx import Presentation
    prs = Presentation(str(p))
    out = []
    for s in prs.slides:
        texts = []
        title = None
        try:
            if s.shapes.title is not None:
                title = s.shapes.title.text_frame.text.strip()
        except Exception:
            pass
        for sh in s.shapes:
            if sh.has_text_frame:
                t = sh.text_frame.text.strip()
                if t:
                    texts.append(t)
        out.append({"title": title, "texts": texts, "all": "\n".join(texts)})
    return out


def pdf_page_texts(p):
    from pypdf import PdfReader
    r = PdfReader(str(p))
    return [(pg.extract_text() or "") for pg in r.pages], [int(pg.get("/Rotate", 0) or 0) % 360 for pg in r.pages]


def docx_paragraphs(p):
    import docx
    d = docx.Document(str(p))
    return d, [para for para in d.paragraphs if para.text.strip()]


def xlsx_sheet_rows(p):
    import openpyxl
    wb = openpyxl.load_workbook(str(p), data_only=False)
    wbv = openpyxl.load_workbook(str(p), data_only=True)
    out = []
    for ws in wb.worksheets:
        wsv = wbv[ws.title]
        rows = []
        for r, rv in zip(ws.iter_rows(), wsv.iter_rows()):
            rows.append([(cv.value if cv.value is not None else c.value) for c, cv in zip(r, rv)])
        out.append(rows)
    return out


def eval_simple_formula(f, rows, r_idx):
    """Evaluate =SUM(B2:E2) or =B2+C2+... against rows (list of lists, 1-indexed in formula)."""
    if not isinstance(f, str) or not f.startswith("="):
        return f

    def ref(col, row):
        c = 0
        for ch in col:
            c = c * 26 + (ord(ch.upper()) - 64)
        v = rows[int(row) - 1][c - 1]
        return float(v) if v not in (None, "") else 0.0

    body = f[1:].replace("$", "")
    m = re.fullmatch(r"SUM\(([A-Z]+)(\d+):([A-Z]+)(\d+)\)", body, re.I)
    if m:
        c1, r1, c2, r2 = m.groups()
        tot = 0.0
        for ci in range(ord(c1.upper()), ord(c2.upper()) + 1):
            for ri in range(int(r1), int(r2) + 1):
                tot += ref(chr(ci), ri)
        return tot
    parts = re.findall(r"([A-Z]+)(\d+)", body, re.I)
    if parts and re.fullmatch(r"([A-Z]+\d+\+)*[A-Z]+\d+", body, re.I):
        return sum(ref(c, r) for c, r in parts)
    return None


def zip_names(p):
    with zipfile.ZipFile(str(p)) as z:
        return z.namelist()


def zip_read(p, name):
    with zipfile.ZipFile(str(p)) as z:
        return z.read(name).decode("utf-8", errors="replace")
