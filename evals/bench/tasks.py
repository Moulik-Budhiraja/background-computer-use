"""The task suite. Each task has setup, a deterministic checker on final state,
and known-good / known-bad end states used to validate the checker."""
import csv
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Optional

from . import fixtures as F
from .common import (Ctx, Result, cell_str, csv_rows, docx_paragraphs, eval_simple_formula, extract_answer,
                     find_header_table, finder_tags, norm, num, numbers_tables, pdf_page_texts, pptx_slide_texts,
                     said_infeasible, set_finder_tags, sha256, textutil, xlsx_sheet_rows, zip_names, zip_read)

BUDGET = {"easy": 480, "medium": 900, "hard": 1500, "infeasible": 480}
STEP_BUDGET = {"easy": 30, "medium": 60, "hard": 120, "infeasible": 30}


@dataclass
class Task:
    id: str
    tier: str  # easy | medium | hard | infeasible
    category: str  # web-local | web-public | native | finder | settings | multi-app | infeasible
    apps: List[str]
    mechanics: List[str]
    instruction: str  # may use {work} and {url}
    setup: Callable[[Ctx], None]
    check: Callable[[Ctx, str], Result]
    good: Callable[[Ctx], str]  # makes a known-good end state, returns a final message
    bad: Callable[[Ctx], str]  # makes a known-bad end state, returns a final message
    infeasible: bool = False
    network: bool = False

    @property
    def budget_s(self):
        return BUDGET[self.tier]

    @property
    def step_budget(self):
        return STEP_BUDGET[self.tier]

    def prompt(self, ctx: Ctx):
        return self.instruction.format(work=str(ctx.work), url=ctx.url)


TASKS: List[Task] = []


def nothing(ctx):
    pass


def base(text, feasible=True):
    r = Result()
    r.answer = extract_answer(text)
    r.said_infeasible = said_infeasible(text)
    if feasible:
        r.subgoals["did_not_claim_infeasible"] = not r.said_infeasible
    return r


def answer_task(r: Result, ok: bool, name="answer_correct"):
    r.subgoals[name] = ok
    return r


# =====================================================================
# EASY
# =====================================================================

# E01 signup form (localhost)
def e01_check(ctx, text):
    r = base(text)
    subs = ctx.submissions("signup")
    s = subs[-1] if subs else {}
    r.subgoals["submitted"] = bool(subs)
    r.subgoals["name"] = s.get("name", "").strip() == "Ada Lovelace"
    r.subgoals["email"] = s.get("email", "").strip().lower() == "ada@example.org"
    r.subgoals["country"] = s.get("country") == "Canada"
    r.subgoals["plan"] = s.get("plan") == "Pro"
    r.subgoals["agreed"] = s.get("agree") == "yes"
    r.subgoals["single_submission"] = len(subs) <= 1
    return r


def e01_write(ctx, data):
    import json, time
    with open(ctx.web_log, "a") as f:
        f.write(json.dumps({"kind": "submit", "form": "signup", "data": data, "t": time.time()}) + "\n")


TASKS.append(Task(
    id="E01_web_signup_form", tier="easy", category="web-local", apps=["browser"], mechanics=["form", "select", "checkbox"],
    instruction="In the web browser, open {url}/signup.html and create an account with these details: full name Ada Lovelace, "
                "email ada@example.org, country Canada, plan Pro. Agree to the terms, then click Create account.",
    setup=nothing, check=e01_check,
    good=lambda c: (e01_write(c, {"name": "Ada Lovelace", "email": "ada@example.org", "country": "Canada", "plan": "Pro", "agree": "yes"}), "Done.")[1],
    bad=lambda c: (e01_write(c, {"name": "Ada Lovelace", "email": "ada@example.org", "country": "Canada", "plan": "Free"}), "Done.")[1],
))


# E02 inventory lookup (localhost)
def e02_answer():
    rows = F.inventory_rows()
    return min((r for r in rows if r["Category"] == "Garden"), key=lambda r: r["Price"])["Product"]


TASKS.append(Task(
    id="E02_web_table_lookup", tier="easy", category="web-local", apps=["browser"], mechanics=["read", "scroll"],
    instruction="In the web browser, open {url}/data/inventory.html. Which product in the Garden category has the lowest price? "
                "Reply with the product name.",
    setup=lambda c: F.write_inventory_page(c),
    check=lambda c, t: answer_task(base(t), norm(extract_answer(t)) == norm(e02_answer())),
    good=lambda c: f"ANSWER: {e02_answer()}",
    bad=lambda c: "ANSWER: Trowel" if e02_answer() != "Trowel" else "ANSWER: Rake",
))

# E03 Wikipedia featured article (public, read-only)
TASKS.append(Task(
    id="E03_web_wikipedia_tfa", tier="easy", category="web-public", apps=["browser"], mechanics=["navigate", "read"],
    instruction="Using the web browser, find out which article was Wikipedia's (English) Today's featured article on "
                "14 September 2026. Reply with the article's title.",
    setup=nothing, network=True,
    check=lambda c, t: answer_task(base(t), "melisende" in norm(extract_answer(t))),
    good=lambda c: "ANSWER: Melisende of Jerusalem",
    bad=lambda c: "ANSWER: Baldwin II of Jerusalem",
))


# E04 System Settings about (read-only)
def e04_truth():
    import subprocess
    mem = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // (1024 ** 3)
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    return chip, mem


def e04_check(ctx, text):
    r = base(text)
    chip, mem = e04_truth()
    a = (extract_answer(text) or "").lower()
    r.subgoals["chip"] = chip.lower().replace("apple ", "") in a
    r.subgoals["memory"] = bool(re.search(rf"\b{mem}\s*gb", a))
    return r


TASKS.append(Task(
    id="E04_settings_about", tier="easy", category="settings", apps=["System Settings"], mechanics=["navigate", "read"],
    instruction="Open System Settings and look at General > About (don't change anything). Which chip does this Mac have, and how much "
                "memory? Reply in the form: <chip>, <memory>.",
    setup=nothing, check=e04_check,
    good=lambda c: "ANSWER: %s, %d GB" % e04_truth(),
    bad=lambda c: "ANSWER: Apple M2, 16 GB",
))

# E05 count CSVs in Finder
TASKS.append(Task(
    id="E05_finder_count", tier="easy", category="finder", apps=["Finder"], mechanics=["navigate", "go_to_folder", "read"],
    instruction="In Finder, open the folder {work}/inbox. How many files in it have the .csv extension? Reply with the number.",
    setup=lambda c: F.make_inbox(c),
    check=lambda c, t: answer_task(base(t), num(extract_answer(t)) == 6),
    good=lambda c: "ANSWER: 6", bad=lambda c: "ANSWER: 5",
))


# E06 new folder
def e06_check(ctx, text):
    r = base(text)
    r.subgoals["folder_exists"] = (ctx.work / "Archive 2026").is_dir()
    r.subgoals["no_stray_untitled"] = not any(p.name.startswith("untitled folder") for p in ctx.work.iterdir())
    return r


TASKS.append(Task(
    id="E06_finder_new_folder", tier="easy", category="finder", apps=["Finder"], mechanics=["go_to_folder", "rename", "menus"],
    instruction="In Finder, create a new folder named \"Archive 2026\" inside {work}.",
    setup=nothing, check=e06_check,
    good=lambda c: ((c.work / "Archive 2026").mkdir(), "Done.")[1],
    bad=lambda c: ((c.work / "untitled folder").mkdir(), "Done.")[1],
))

# E07 TextEdit plain text
E07_LINES = ["Meeting moved to Thursday.", "Room 4B, 10:30 AM.", "Bring the Q3 numbers."]


def e07_check(ctx, text):
    r = base(text)
    p = ctx.work / "hello.txt"
    r.subgoals["file_saved"] = p.exists()
    raw = p.read_text(errors="replace") if p.exists() else ""
    r.subgoals["plain_text"] = p.exists() and not raw.lstrip().startswith("{\\rtf")
    lines = [l.rstrip() for l in raw.strip("\n").split("\n")]
    r.subgoals["content_exact"] = lines == E07_LINES
    return r


TASKS.append(Task(
    id="E07_textedit_new_plain", tier="easy", category="native", apps=["TextEdit"], mechanics=["typing", "menus", "save_panel"],
    instruction="In TextEdit, create a new document, make it plain text (Format > Make Plain Text), and type exactly these three lines:\n"
                + "\n".join(E07_LINES) + "\nSave it as {work}/hello.txt",
    setup=nothing, check=e07_check,
    good=lambda c: ((c.work / "hello.txt").write_text("\n".join(E07_LINES) + "\n"), "Done.")[1],
    bad=lambda c: ((c.work / "hello.txt").write_text("Meeting moved to Thursday.\nRoom 4B, 10:30 AM.\nBring the Q3 numbers\n"), "Done.")[1],
))


# E08 Preview read page 4 heading
def e08_setup(ctx):
    F.make_pdf(ctx.work / "report.pdf", [f"Section {i + 1}: {h}\nBody text for section {i + 1}." for i, h in enumerate(F.REPORT_HEADINGS)])


TASKS.append(Task(
    id="E08_preview_read_page", tier="easy", category="native", apps=["Preview"], mechanics=["open_panel", "scroll", "read"],
    instruction="Open {work}/report.pdf in Preview. What is the heading on page 4? Reply with the heading text.",
    setup=e08_setup,
    check=lambda c, t: answer_task(base(t), "amber signal" in norm(extract_answer(t))),
    good=lambda c: "ANSWER: Section 4: Amber Signal", bad=lambda c: "ANSWER: Section 3: Velvet Compass",
))

# E09 Numbers read a cell
E09_TRUTH = F.budget_values()["Travel"][2]
TASKS.append(Task(
    id="E09_numbers_read_cell", tier="easy", category="native", apps=["Numbers"], mechanics=["open_panel", "read"],
    instruction="Open {work}/budget.numbers in Numbers. What is the amount for Travel in March? Reply with the number.",
    setup=lambda c: F.make_budget_numbers(c.work / "budget.numbers"),
    check=lambda c, t: answer_task(base(t), num(extract_answer(t)) is not None and abs(num(extract_answer(t)) - E09_TRUTH) < 0.006),
    good=lambda c: f"ANSWER: {E09_TRUTH:,.2f}", bad=lambda c: f"ANSWER: {F.budget_values()['Travel'][1]:.2f}",
))

# E10 docs site navigation (localhost)
TASKS.append(Task(
    id="E10_web_docs_navigation", tier="easy", category="web-local", apps=["browser"], mechanics=["navigate", "tabs", "disclosure"],
    instruction="In the web browser, open {url}/docs/index.html. Find the real activation code for Nimbus (not the demo code). "
                "Reply with the code.",
    setup=nothing,
    check=lambda c, t: answer_task(base(t), "zk-4471-q" in norm(extract_answer(t))),
    good=lambda c: "ANSWER: ZK-4471-Q", bad=lambda c: "ANSWER: NB-0000-X",
))


# E11 PyPI release date (public, read-only)
def e11_ok(a):
    a = norm(a)
    return bool(re.search(r"2026-10-10|oct(ober)?\.? 10,? 2026|10 oct(ober)? 2026", a))


TASKS.append(Task(
    id="E11_web_pypi_release_date", tier="easy", category="web-public", apps=["browser"], mechanics=["navigate", "read"],
    instruction="Using the web browser, look up the Python package numbers-parser on pypi.org. On what date was version 4.20.0 "
                "released? Reply with the date as YYYY-MM-DD.",
    setup=nothing, network=True,
    check=lambda c, t: answer_task(base(t), e11_ok(extract_answer(t))),
    good=lambda c: "ANSWER: 2026-10-10", bad=lambda c: "ANSWER: 2026-10-13",
))

# =====================================================================
# MEDIUM
# =====================================================================

# M01 TextEdit find/replace + bold heading, save in place
LETTER_EXPECT = [p.replace("Acme Corp", "Globex Inc") for p in F.LETTER_PARAS]


def m01_check(ctx, text):
    r = base(text)
    p = ctx.work / "letter.rtf"
    txt = textutil(p) if p.exists() else ""
    html = textutil(p, "html") if p.exists() else ""
    paras = [l.strip() for l in txt.split("\n") if l.strip()]
    r.subgoals["no_acme_left"] = p.exists() and "Acme Corp" not in txt
    r.subgoals["globex_count_4"] = txt.count("Globex Inc") == 4
    r.subgoals["rest_unchanged"] = paras == LETTER_EXPECT
    m = re.search(r"<body>\s*<p[^>]*>(.*?)</p>", html, re.S)
    first = m.group(1) if m else ""
    r.subgoals["heading_bold"] = "<b>" in first and "Partnership Proposal" in re.sub(r"<[^>]+>", "", first)
    # body should not be bold
    rest = html[m.end():] if m else ""
    r.subgoals["body_not_bold"] = bool(m) and not re.search(r"<b>[^<]*(Dear|Thank you|Sincerely)", rest)
    return r


TASKS.append(Task(
    id="M01_textedit_replace_bold", tier="medium", category="native", apps=["TextEdit"],
    mechanics=["open_panel", "find_replace", "selection", "keyboard", "save"],
    instruction="Open {work}/letter.rtf in TextEdit. Replace every occurrence of \"Acme Corp\" with \"Globex Inc\", make the first line "
                "(\"Partnership Proposal\") bold, and save the document in place (keep it as letter.rtf, rich text).",
    setup=lambda c: F.write_rtf(c.work / "letter.rtf", F.LETTER_PARAS),
    check=m01_check,
    good=lambda c: (F.write_rtf(c.work / "letter.rtf", LETTER_EXPECT, bold_first=True), "Done.")[1],
    bad=lambda c: (F.write_rtf(c.work / "letter.rtf", [p.replace("Acme Corp", "Globex Inc", 2) for p in F.LETTER_PARAS]), "Done.")[1],
))


# M02 TextEdit rich formatting new doc
def m02_check(ctx, text):
    r = base(text)
    p = ctx.work / "weekly.rtf"
    r.subgoals["file_saved"] = p.exists()
    raw = p.read_text(errors="replace") if p.exists() else ""
    r.subgoals["is_rtf"] = raw.startswith("{\\rtf")
    txt = textutil(p) if p.exists() else ""
    paras = [l.strip() for l in txt.split("\n") if l.strip()]
    r.subgoals["text_exact"] = paras == ["Weekly Report", "All milestones are on track."]
    i = raw.find("Weekly Report")
    pre = raw[:i] if i >= 0 else ""
    sizes = re.findall(r"\\fs(\d+)", pre)
    r.subgoals["title_24pt"] = bool(sizes) and sizes[-1] == "48"
    html = textutil(p, "html") if p.exists() else ""
    m = re.search(r"<body>\s*<p[^>]*>(.*?)</p>", html, re.S)
    r.subgoals["title_bold"] = bool(m) and "<b>" in m.group(1)
    j = raw.find("All milestones")
    pre2 = raw[i:j] if (i >= 0 and j > i) else ""
    s2 = re.findall(r"\\fs(\d+)", pre2)
    r.subgoals["body_not_24pt"] = j > 0 and (not s2 or s2[-1] != "48")
    return r


TASKS.append(Task(
    id="M02_textedit_rich_format", tier="medium", category="native", apps=["TextEdit"],
    mechanics=["typing", "selection", "font_panel", "save_panel"],
    instruction="In TextEdit, create a new rich text document with two lines. First line: \"Weekly Report\", in bold at 24 pt. "
                "Second line: \"All milestones are on track.\" in normal (not bold) text at the default size. Save it as {work}/weekly.rtf",
    setup=nothing, check=m02_check,
    good=lambda c: (F.write_rtf(c.work / "weekly.rtf", ["Weekly Report", "All milestones are on track."], bold_first=True, first_size=48), "Done.")[1],
    bad=lambda c: (F.write_rtf(c.work / "weekly.rtf", ["Weekly Report", "All milestones are on track."], bold_first=True), "Done.")[1],
))


# M03 Pages edit docx and export
def m03_check(ctx, text):
    r = base(text)
    p = ctx.work / "memo_final.docx"
    r.subgoals["exported"] = p.exists()
    if not p.exists():
        for k in ("title_changed", "paragraph_appended", "body_unchanged"):
            r.subgoals[k] = False
        return r
    _, paras = docx_paragraphs(p)
    texts = [x.text.strip() for x in paras]
    r.subgoals["title_changed"] = bool(texts) and texts[0] == "Final Memo" and "Draft Memo" not in texts
    r.subgoals["paragraph_appended"] = bool(texts) and texts[-1] == "Approved by the committee on 3 November 2026."
    r.subgoals["body_unchanged"] = texts[1:4] == F.MEMO_BODY
    return r


def m03_good(ctx, ok=True):
    import docx
    d = docx.Document()
    d.add_paragraph("Final Memo" if ok else "Draft Memo", style="Title")
    for b in F.MEMO_BODY:
        d.add_paragraph(b)
    d.add_paragraph("Approved by the committee on 3 November 2026.")
    d.save(str(ctx.work / "memo_final.docx"))
    return "Done."


TASKS.append(Task(
    id="M03_pages_edit_export_docx", tier="medium", category="native", apps=["Pages"],
    mechanics=["open_panel", "text_edit", "export_dialog", "save_panel"],
    instruction="Open {work}/memo.docx in Pages. Change the title from \"Draft Memo\" to \"Final Memo\", and add a new last paragraph: "
                "\"Approved by the committee on 3 November 2026.\" Then export it as a Word document to {work}/memo_final.docx",
    setup=lambda c: F.make_docx_memo(c.work / "memo.docx"),
    check=m03_check, good=m03_good, bad=lambda c: m03_good(c, ok=False),
))


# M04 Numbers: open CSV, sort, save .numbers
def m04_check(ctx, text):
    r = base(text)
    p = ctx.work / "inventory_sorted.numbers"
    r.subgoals["saved"] = p.exists()
    if not p.exists():
        r.subgoals["sorted_desc"] = r.subgoals["rows_intact"] = False
        return r
    idx, data = find_header_table(numbers_tables(p), ["Item", "SKU", "Quantity"])
    if idx is None:
        r.subgoals["sorted_desc"] = r.subgoals["rows_intact"] = False
        r.notes.append("no table with Item/SKU/Quantity header")
        return r
    got = [(cell_str(row[idx["item"]]), cell_str(row[idx["sku"]]), num(row[idx["quantity"]])) for row in data]
    exp = sorted([(a, b, float(q)) for a, b, q, _ in F.INVENTORY_CSV[1:]], key=lambda x: -x[2])
    r.subgoals["sorted_desc"] = [g[2] for g in got] == [e[2] for e in exp]
    r.subgoals["rows_intact"] = sorted(got) == sorted(exp)
    return r


TASKS.append(Task(
    id="M04_numbers_sort_csv", tier="medium", category="native", apps=["Numbers"],
    mechanics=["open_panel", "sort", "menus", "save_panel"],
    instruction="Open {work}/inventory.csv in Numbers. Sort the table by Quantity from largest to smallest (keep each row together), "
                "then save it as a Numbers spreadsheet at {work}/inventory_sorted.numbers",
    setup=lambda c: F.write_inventory_csv(c.work / "inventory.csv"),
    check=m04_check,
    good=lambda c: (F.write_numbers(c.work / "inventory_sorted.numbers",
                                    [list(F.INVENTORY_CSV[0])] + sorted([list(x) for x in F.INVENTORY_CSV[1:]], key=lambda x: -x[2])), "Done.")[1],
    bad=lambda c: (F.write_numbers(c.work / "inventory_sorted.numbers",
                                   [list(F.INVENTORY_CSV[0])] + [[a, b, q2, l] for (a, b, _, l), q2 in
                                                                 zip(F.INVENTORY_CSV[1:], sorted([x[2] for x in F.INVENTORY_CSV[1:]], reverse=True))]), "Done.")[1],
))


# M05 Numbers: total column, export xlsx
def m05_check(ctx, text):
    r = base(text)
    p = ctx.work / "sales_total.xlsx"
    r.subgoals["exported"] = p.exists()
    keys = ("total_header", "totals_correct", "data_unchanged")
    if not p.exists():
        for k in keys:
            r.subgoals[k] = False
        return r
    best = None
    for rows in xlsx_sheet_rows(p):
        for hi, row in enumerate(rows[:5]):
            cells = [cell_str(c).lower() if c is not None else "" for c in row]
            if "region" in cells and "total" in cells:
                best = (rows, hi, cells.index("region"), cells.index("total"), cells)
                break
        if best:
            break
    r.subgoals["total_header"] = best is not None
    if not best:
        r.subgoals["totals_correct"] = r.subgoals["data_unchanged"] = False
        return r
    rows, hi, ci_reg, ci_tot, cells = best
    exp = {s[0]: s[1:] for s in F.SALES}
    ok_tot, ok_data, seen = True, True, set()
    qcols = [cells.index(q.lower()) for q in ("Q1", "Q2", "Q3", "Q4") if q.lower() in cells]
    for ri in range(hi + 1, len(rows)):
        row = rows[ri]
        reg = cell_str(row[ci_reg]) if row[ci_reg] is not None else ""
        if reg not in exp:
            continue
        seen.add(reg)
        v = row[ci_tot]
        if isinstance(v, str) and v.startswith("="):
            v = eval_simple_formula(v, rows, ri)
        if v is None or abs(float(v) - sum(exp[reg])) > 0.01:
            ok_tot = False
        if len(qcols) != 4 or [float(row[c]) for c in qcols] != [float(x) for x in exp[reg]]:
            ok_data = False
    r.subgoals["totals_correct"] = ok_tot and seen == set(exp)
    r.subgoals["data_unchanged"] = ok_data and seen == set(exp)
    return r


def m05_good(ctx, ok=True):
    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.append(["Region", "Q1", "Q2", "Q3", "Q4", "Total"])
    for i, s in enumerate(F.SALES):
        ws.append(list(s) + [f"=SUM(B{i + 2}:E{i + 2})" if ok else sum(s[1:4])])
    wb.save(str(ctx.work / "sales_total.xlsx"))
    return "Done."


TASKS.append(Task(
    id="M05_numbers_total_column_xlsx", tier="medium", category="native", apps=["Numbers"],
    mechanics=["open_panel", "cell_entry", "formula", "export_dialog"],
    instruction="Open {work}/sales.xlsx in Numbers. Add a column named \"Total\" to the right of Q4 that holds each region's Q1–Q4 sum. "
                "Then export the spreadsheet as an Excel file to {work}/sales_total.xlsx",
    setup=lambda c: F.make_sales_xlsx(c.work / "sales.xlsx"),
    check=m05_check, good=m05_good, bad=lambda c: m05_good(c, ok=False),
))

# M06 Keynote create and export pptx
M06_BULLETS = ["Revenue up 12%", "Two new markets", "Churn down to 3%"]


def m06_check(ctx, text):
    r = base(text)
    p = ctx.work / "review.pptx"
    r.subgoals["exported"] = p.exists()
    slides = pptx_slide_texts(p) if p.exists() else []
    s1 = slides[0]["all"] if slides else ""
    s2 = slides[1]["all"] if len(slides) > 1 else ""
    r.subgoals["two_slides"] = len(slides) == 2
    r.subgoals["slide1_title"] = "Quarterly Review" in s1
    r.subgoals["slide1_subtitle"] = "Q3 2026" in s1
    r.subgoals["slide2_title"] = "Highlights" in s2
    r.subgoals["slide2_bullets"] = all(b in s2 for b in M06_BULLETS)
    return r


def m06_good(ctx, ok=True):
    from pptx import Presentation
    prs = Presentation()
    s = prs.slides.add_slide(prs.slide_layouts[0])
    s.shapes.title.text = "Quarterly Review"
    s.placeholders[1].text = "Q3 2026"
    s = prs.slides.add_slide(prs.slide_layouts[1])
    s.shapes.title.text = "Highlights"
    s.placeholders[1].text = "\n".join(M06_BULLETS if ok else M06_BULLETS[:2])
    prs.save(str(ctx.work / "review.pptx"))
    return "Done."


TASKS.append(Task(
    id="M06_keynote_create_pptx", tier="medium", category="native", apps=["Keynote"],
    mechanics=["theme_chooser", "add_slide", "typing", "export_dialog"],
    instruction="In Keynote, create a new presentation (any theme) with exactly two slides. Slide 1: title \"Quarterly Review\", subtitle "
                "\"Q3 2026\". Slide 2: title \"Highlights\" with three bullet points: \"Revenue up 12%\", \"Two new markets\", "
                "\"Churn down to 3%\". Export it as a PowerPoint file to {work}/review.pptx",
    setup=nothing, check=m06_check, good=m06_good, bad=lambda c: m06_good(c, ok=False),
))


# M07 Preview rotate page 2
def m07_check(ctx, text):
    r = base(text)
    p = ctx.work / "scan.pdf"
    texts, rots = pdf_page_texts(p) if p.exists() else ([], [])
    r.subgoals["three_pages"] = len(rots) == 3
    r.subgoals["page2_rotated_90"] = len(rots) == 3 and rots[1] in (90, 270)
    r.subgoals["others_unrotated"] = len(rots) == 3 and rots[0] == 0 and rots[2] == 0
    r.subgoals["order_kept"] = len(texts) == 3 and all(f"Scan page {i + 1}" in texts[i] for i in range(3))
    return r


def m07_make(ctx, rot2=0, rot_all=0):
    from pypdf import PdfReader, PdfWriter
    F.make_pdf(ctx.work / "scan.pdf", [f"Scan page {i + 1}\nScanned document." for i in range(3)])
    rd = PdfReader(str(ctx.work / "scan.pdf"))
    w = PdfWriter()
    for i, pg in enumerate(rd.pages):
        if rot_all or (i == 1 and rot2):
            pg.rotate(rot_all or rot2)
        w.add_page(pg)
    with open(ctx.work / "scan.pdf", "wb") as f:
        w.write(f)
    return "Done."


TASKS.append(Task(
    id="M07_preview_rotate_page", tier="medium", category="native", apps=["Preview"],
    mechanics=["open_panel", "thumbnails", "menus", "save"],
    instruction="Open {work}/scan.pdf in Preview. Page 2 was scanned sideways: rotate only page 2 by 90 degrees (either direction), "
                "leave pages 1 and 3 as they are, and save the PDF in place.",
    setup=lambda c: m07_make(c), check=m07_check,
    good=lambda c: m07_make(c, rot2=90), bad=lambda c: m07_make(c, rot_all=90),
))


# M08 Finder rename + tag
def m08_check(ctx, text):
    r = base(text)
    d = ctx.work / "photos"
    b = d / "beach.jpg"
    r.subgoals["renamed"] = b.exists() and not (d / "IMG_0042.jpg").exists()
    r.subgoals["same_file"] = b.exists() and sha256(b) == ctx_hash(ctx)
    r.subgoals["red_tag"] = b.exists() and "Red" in finder_tags(b)
    others = [f"IMG_00{n}.jpg" for n in (40, 41, 43, 44, 45)]
    r.subgoals["others_untouched"] = all((d / o).exists() and not finder_tags(d / o) for o in others)
    return r


def ctx_hash(ctx):
    p = ctx.work.parent / f".m08-{ctx.lane}.sha"
    return p.read_text() if p.exists() else ""


def m08_setup(ctx):
    d = F.photos(ctx)
    (ctx.work.parent / f".m08-{ctx.lane}.sha").write_text(sha256(d / "IMG_0042.jpg"))


def m08_good(ctx, ok=True):
    d = ctx.work / "photos"
    (d / "IMG_0042.jpg").rename(d / "beach.jpg")
    set_finder_tags(d / "beach.jpg", ["Red"] if ok else ["Orange"])
    return "Done."


TASKS.append(Task(
    id="M08_finder_rename_tag", tier="medium", category="finder", apps=["Finder"],
    mechanics=["go_to_folder", "rename", "context_menu", "tags"],
    instruction="In Finder, go to {work}/photos. Rename IMG_0042.jpg to beach.jpg and give it the Red tag. Don't change the other photos.",
    setup=m08_setup, check=m08_check, good=m08_good, bad=lambda c: m08_good(c, ok=False),
))


# M09 Finder move PDFs into new folder
PDFS = [n for n in F.INBOX_FILES if n.endswith(".pdf")]


def m09_check(ctx, text):
    r = base(text)
    inbox = ctx.work / "inbox"
    dest = inbox / "PDFs"
    r.subgoals["folder_created"] = dest.is_dir()
    r.subgoals["all_pdfs_moved"] = dest.is_dir() and all((dest / n).exists() for n in PDFS) and not any((inbox / n).exists() for n in PDFS)
    non = [n for n in F.INBOX_FILES if not n.endswith(".pdf")]
    r.subgoals["others_stay"] = all((inbox / n).exists() for n in non) and (not dest.is_dir() or all(not (dest / n).exists() for n in non))
    return r


def m09_good(ctx, ok=True):
    inbox = ctx.work / "inbox"
    (inbox / "PDFs").mkdir()
    for n in (PDFS if ok else PDFS[:3]):
        (inbox / n).rename(inbox / "PDFs" / n)
    return "Done."


TASKS.append(Task(
    id="M09_finder_move_pdfs", tier="medium", category="finder", apps=["Finder"],
    mechanics=["go_to_folder", "new_folder", "multi_select", "drag_or_cut_paste"],
    instruction="In Finder, go to {work}/inbox. Create a folder named \"PDFs\" inside it and move every .pdf file from inbox into that "
                "folder. Leave all other files where they are.",
    setup=lambda c: F.make_inbox(c), check=m09_check, good=m09_good, bad=lambda c: m09_good(c, ok=False),
))


# M10 complex booking form (localhost)
def m10_check(ctx, text):
    r = base(text)
    subs = ctx.submissions("booking")
    s = subs[-1] if subs else {}
    req = s.get("requests", [])
    req = [req] if isinstance(req, str) else req
    r.subgoals["submitted"] = bool(subs)
    r.subgoals["date"] = s.get("date") == "2026-12-05"
    r.subgoals["time"] = s.get("time") == "19:30"
    r.subgoals["seating"] = s.get("seating") == "Patio"
    r.subgoals["requests"] = sorted(req) == ["Quiet table", "Vegetarian menu"]
    r.subgoals["party"] = s.get("party") == "6"
    notes = (s.get("notes") or "").replace("\r\n", "\n").strip()
    r.subgoals["notes_two_lines"] = [l.strip() for l in notes.split("\n")] == ["Celebrating a birthday.", "Please no nuts."]
    return r


def m10_write(ctx, data):
    import json, time
    with open(ctx.web_log, "a") as f:
        f.write(json.dumps({"kind": "submit", "form": "booking", "data": data, "t": time.time()}) + "\n")
    return "Done."


TASKS.append(Task(
    id="M10_web_booking_form", tier="medium", category="web-local", apps=["browser"],
    mechanics=["form", "date_input", "radio", "checkbox", "slider", "multiline_text"],
    instruction="In the web browser, open {url}/booking.html and book a table: date 5 December 2026, time 19:30, Patio seating, "
                "requests: Vegetarian menu and Quiet table (nothing else), party size 6, and this two-line note:\n"
                "Celebrating a birthday.\nPlease no nuts.\nThen click Book table.",
    setup=nothing, check=m10_check,
    good=lambda c: m10_write(c, {"date": "2026-12-05", "time": "19:30", "seating": "Patio", "requests": ["Vegetarian menu", "Quiet table"],
                                 "party": "6", "notes": "Celebrating a birthday.\r\nPlease no nuts."}),
    bad=lambda c: m10_write(c, {"date": "2026-12-05", "time": "19:30", "seating": "Patio", "requests": "Vegetarian menu",
                                "party": "2", "notes": "Celebrating a birthday. Please no nuts."}),
))


# M11 checkout wizard (localhost)
M11 = {"fullname": "Jordan Lee", "email": "jordan.lee@example.com", "street": "1200 Market Street", "city": "Denver",
       "state": "Colorado", "zip": "80202", "speed": "Express"}


def m11_check(ctx, text):
    r = base(text)
    subs = ctx.submissions("wizard")
    s = subs[-1] if subs else {}
    r.subgoals["order_placed"] = bool(subs)
    for k, v in M11.items():
        r.subgoals[k] = (s.get(k) or "").strip() == v
    return r


def m11_write(ctx, data):
    import json, time
    with open(ctx.web_log, "a") as f:
        f.write(json.dumps({"kind": "submit", "form": "wizard", "data": data, "t": time.time()}) + "\n")
    return "Done."


TASKS.append(Task(
    id="M11_web_checkout_wizard", tier="medium", category="web-local", apps=["browser"],
    mechanics=["multi_step_form", "validation", "select", "radio", "checkbox"],
    instruction="In the web browser, open {url}/wizard.html and complete the 3-step checkout: name Jordan Lee, email "
                "jordan.lee@example.com, shipping to 1200 Market Street, Denver, Colorado 80202, with Express delivery. "
                "Confirm the details and place the order.",
    setup=nothing, check=m11_check,
    good=lambda c: m11_write(c, dict(M11)), bad=lambda c: m11_write(c, dict(M11, speed="Standard")),
))

# M12 GitHub releases (public, read-only)
TASKS.append(Task(
    id="M12_web_github_releases", tier="medium", category="web-public", apps=["browser"], mechanics=["navigate", "scroll", "paginate", "read"],
    instruction="Using the web browser, open the GitHub releases page of the astral-sh/ruff repository. Which version was the first "
                "release published in September 2026? Reply with the version number.",
    setup=nothing, network=True,
    check=lambda c, t: answer_task(base(t), bool(re.search(r"(^|[^\d.])0\.16\.6($|[^\d])", extract_answer(t) or ""))),
    good=lambda c: "ANSWER: 0.16.6", bad=lambda c: "ANSWER: 0.16.10",
))


# M13 System Settings: separate Spaces (read-only)
def m13_truth():
    r = subprocess.run(["defaults", "read", "com.apple.spaces", "spans-displays"], capture_output=True, text=True)
    return not (r.returncode == 0 and r.stdout.strip() == "1")  # key absent or 0 => separate Spaces on


def m13_check(ctx, text):
    r = base(text)
    a = norm(extract_answer(text))
    on = bool(re.match(r"^(on|yes|enabled|true)\b", a))
    off = bool(re.match(r"^(off|no|disabled|false)\b", a))
    r.subgoals["answer_correct"] = (on and m13_truth()) or (off and not m13_truth())
    return r


TASKS.append(Task(
    id="M13_settings_separate_spaces", tier="medium", category="settings", apps=["System Settings"],
    mechanics=["navigate", "scroll", "read"],
    instruction="Open System Settings > Desktop & Dock (read only, don't change anything). Is the setting \"Displays have separate Spaces\" "
                "turned on or off? Reply with On or Off.",
    setup=nothing, check=m13_check,
    good=lambda c: "ANSWER: " + ("On" if m13_truth() else "Off"),
    bad=lambda c: "ANSWER: " + ("Off" if m13_truth() else "On"),
))


# M14 Notes create + export PDF
def m14_title(ctx):
    return f"BCU Eval Packing List {ctx.lane.upper()}"


def m14_check(ctx, text):
    r = base(text)
    p = ctx.work / "packing.pdf"
    r.subgoals["exported"] = p.exists()
    t = " ".join(pdf_page_texts(p)[0]) if p.exists() else ""
    r.subgoals["title"] = m14_title(ctx) in t
    r.subgoals["items"] = all(x in t for x in ("Passport", "Charger", "Umbrella"))
    return r


TASKS.append(Task(
    id="M14_notes_export_pdf", tier="medium", category="native", apps=["Notes"], mechanics=["typing", "menus", "export_dialog", "delete"],
    instruction="In Notes, create a new note whose first line (title) is \"{lane_title}\" followed by three lines: Passport, Charger, "
                "Umbrella. Export the note as a PDF to {work}/packing.pdf. Then delete that note from Notes, so nothing is left behind.",
    setup=nothing, check=m14_check,
    good=lambda c: (F.make_pdf(c.work / "packing.pdf", [f"{m14_title(c)}\nPassport\nCharger\nUmbrella"]), "Done.")[1],
    bad=lambda c: (F.make_pdf(c.work / "packing.pdf", [f"{m14_title(c)}\nPassport\nCharger"]), "Done.")[1],
))

# =====================================================================
# HARD
# =====================================================================


# H01 web table -> Numbers with computed column
def h01_check(ctx, text):
    r = base(text)
    p = ctx.work / "cities.numbers"
    r.subgoals["saved"] = p.exists()
    keys = ("headers", "all_rows", "density_correct")
    if not p.exists():
        for k in keys:
            r.subgoals[k] = False
        return r
    idx, data = find_header_table(numbers_tables(p), ["City", "Population", "Area", "Density"])
    r.subgoals["headers"] = idx is not None
    if idx is None:
        r.subgoals["all_rows"] = r.subgoals["density_correct"] = False
        return r
    got = {cell_str(row[idx["city"]]): row for row in data}
    ok_rows, ok_den = True, True
    for c, pop, area in F.CITIES:
        row = got.get(c)
        if row is None or num(row[idx["population"]]) != pop or abs((num(row[idx["area"]]) or 0) - area) > 1e-6:
            ok_rows = False
        if row is None or num(row[idx["density"]]) is None or abs(num(row[idx["density"]]) - pop / area) > 0.051:
            ok_den = False
    r.subgoals["all_rows"] = ok_rows and len(got) == len(F.CITIES)
    r.subgoals["density_correct"] = ok_den
    return r


def h01_good(ctx, ok=True):
    rows = [["City", "Population", "Area", "Density"]] + [[c, p, a, round(p / a, 1) if ok else round(a / p * 1000, 1)] for c, p, a in F.CITIES]
    F.write_numbers(ctx.work / "cities.numbers", rows)
    return "Done."


TASKS.append(Task(
    id="H01_web_table_to_numbers", tier="hard", category="multi-app", apps=["browser", "Numbers"],
    mechanics=["read_web", "template_chooser", "cell_entry", "formula", "save_panel"],
    instruction="The web page {url}/data/cities.html has a table of cities. In Numbers, create a new spreadsheet with a table whose columns are "
                "City, Population, Area and Density, holding every city from that page, where Density is Population divided by Area "
                "(rounded to 1 decimal place is fine). Save it as {work}/cities.numbers",
    setup=lambda c: F.write_cities_page(c), check=h01_check, good=h01_good, bad=lambda c: h01_good(c, ok=False),
))


# H02 text file -> Pages with heading -> docx
def h02_check(ctx, text):
    r = base(text)
    p = ctx.work / "abstract.docx"
    r.subgoals["exported"] = p.exists()
    if not p.exists():
        r.subgoals["heading_text"] = r.subgoals["heading_styled"] = r.subgoals["paragraph_exact"] = False
        return r
    d, paras = docx_paragraphs(p)
    r.subgoals["heading_text"] = bool(paras) and paras[0].text.strip() == "Project Abstract"
    styled = False
    if paras:
        h = paras[0]
        sname = (h.style.name or "").lower() if h.style is not None else ""
        runs = [x for x in h.runs if x.text.strip()]
        big = any(x.font.size and x.font.size.pt >= 16 for x in runs)
        if not big and h.style is not None and h.style.font is not None and h.style.font.size:
            big = h.style.font.size.pt >= 16
        bold = runs and all(x.bold or (h.style is not None and h.style.font is not None and h.style.font.bold) for x in runs)
        styled = ("heading" in sname or "title" in sname or big or bool(bold))
    r.subgoals["heading_styled"] = styled
    body = " ".join(x.text.strip() for x in paras[1:])
    r.subgoals["paragraph_exact"] = norm(body) == norm(F.ABSTRACT)
    return r


def h02_good(ctx, ok=True):
    import docx
    d = docx.Document()
    d.add_paragraph("Project Abstract", style="Heading 1" if ok else None)
    d.add_paragraph(F.ABSTRACT if ok else F.ABSTRACT[:120])
    d.save(str(ctx.work / "abstract.docx"))
    return "Done."


TASKS.append(Task(
    id="H02_textfile_to_pages_docx", tier="hard", category="multi-app", apps=["TextEdit", "Pages"],
    mechanics=["open_panel", "copy_text_between_apps", "template_chooser", "paragraph_style", "export_dialog"],
    instruction="The file {work}/inbox/abstract.txt holds one paragraph. Make a Pages document that starts with the heading "
                "\"Project Abstract\" (formatted as a heading or title, not body text), followed by that paragraph exactly as written. "
                "Export it as a Word document to {work}/abstract.docx",
    setup=lambda c: F.make_inbox(c), check=h02_check, good=h02_good, bad=lambda c: h02_good(c, ok=False),
))


# H03 Numbers chart export
def h03_check(ctx, text):
    r = base(text)
    p = ctx.work / "sales_chart.xlsx"
    r.subgoals["exported"] = p.exists()
    charts = [n for n in zip_names(p) if re.match(r"xl/charts/chart\d+\.xml", n)] if p.exists() else []
    r.subgoals["has_chart"] = bool(charts)
    xmls = [zip_read(p, n) for n in charts]
    r.subgoals["bar_or_column"] = any(re.search(r"<(?:\w+:)?barChart\b", x) for x in xmls)
    q4 = {float(s[4]) for s in F.SALES}
    ok = False
    for x in xmls:
        vals = {float(v) for v in re.findall(r"<(?:\w+:)?v>(-?[\d.]+)</(?:\w+:)?v>", x)}
        refs = re.findall(r"<(?:\w+:)?val>.*?<(?:\w+:)?f>([^<]+)</", x, re.S)
        if q4 <= vals or any(re.search(r"\$?E\$?2:\$?E\$?7", f) for f in refs):
            ok = True
    r.subgoals["plots_q4"] = ok
    return r


def h03_good(ctx, ok=True):
    import openpyxl
    from openpyxl.chart import BarChart, LineChart, Reference
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.append(["Region", "Q1", "Q2", "Q3", "Q4"])
    for s in F.SALES:
        ws.append(list(s))
    ch = BarChart() if ok else LineChart()
    ch.add_data(Reference(ws, min_col=5, min_row=1, max_row=7), titles_from_data=True)
    ch.set_categories(Reference(ws, min_col=1, min_row=2, max_row=7))
    ws.add_chart(ch, "H2")
    wb.save(str(ctx.work / "sales_chart.xlsx"))
    # openpyxl writes no cached values; add them so the good state mirrors a Numbers export
    if ok:
        import zipfile, shutil
        src = ctx.work / "sales_chart.xlsx"
        tmp = ctx.work / "tmp.xlsx"
        with zipfile.ZipFile(src) as zi, zipfile.ZipFile(tmp, "w") as zo:
            for it in zi.infolist():
                data = zi.read(it.filename)
                if it.filename.startswith("xl/charts/chart"):
                    s = data.decode()
                    cache = "".join(f"<c:pt idx=\"{i}\"><c:v>{v[4]}</c:v></c:pt>" for i, v in enumerate(F.SALES))
                    s = s.replace("</c:f></c:numRef>", f"</c:f><c:numCache><c:ptCount val=\"6\"/>{cache}</c:numCache></c:numRef>", 1)
                    data = s.encode()
                zo.writestr(it, data)
        shutil.move(tmp, src)
    return "Done."


TASKS.append(Task(
    id="H03_numbers_chart_xlsx", tier="hard", category="native", apps=["Numbers"],
    mechanics=["open_panel", "select_range", "insert_chart", "export_dialog"],
    instruction="Open {work}/sales.xlsx in Numbers. Add a bar or column chart that shows the Q4 value for each region. "
                "Export the spreadsheet (with the chart) as an Excel file to {work}/sales_chart.xlsx",
    setup=lambda c: F.make_sales_xlsx(c.work / "sales.xlsx"), check=h03_check, good=h03_good, bad=lambda c: h03_good(c, ok=False),
))


# H04 Keynote reorder + delete slides
def h04_check(ctx, text):
    r = base(text)
    p = ctx.work / "deck_final.pptx"
    r.subgoals["exported"] = p.exists()
    slides = pptx_slide_texts(p) if p.exists() else []

    def title(s):
        if s["title"]:
            return s["title"]
        return s["texts"][0].split("\n")[0] if s["texts"] else ""

    titles = [title(s).strip() for s in slides]
    r.subgoals["draft_deleted"] = p.exists() and not any("DRAFT" in t for t in titles)
    r.subgoals["order_correct"] = titles == F.DECK_OUT
    r.subgoals["five_slides"] = len(titles) == 5
    return r


TASKS.append(Task(
    id="H04_keynote_reorder_delete", tier="hard", category="native", apps=["Keynote"],
    mechanics=["open_panel", "slide_navigator", "drag", "delete", "export_dialog"],
    instruction="Open {work}/deck.pptx in Keynote. Delete the slide titled \"DRAFT - do not present\" and reorder the remaining slides to: "
                "Intro, Method, Results, Conclusion, Questions. Export the result as a PowerPoint file to {work}/deck_final.pptx",
    setup=lambda c: F.make_deck_pptx(c.work / "deck.pptx", F.DECK_IN), check=h04_check,
    good=lambda c: (F.make_deck_pptx(c.work / "deck_final.pptx", F.DECK_OUT), "Done.")[1],
    bad=lambda c: (F.make_deck_pptx(c.work / "deck_final.pptx", ["Intro", "Results", "Method", "Conclusion", "Questions"]), "Done.")[1],
))

# H05 Preview reorder + delete pages
H05_IN = ["A", "B", "C", "D", "E"]
H05_OUT = ["E", "A", "B", "D"]


def h05_check(ctx, text):
    r = base(text)
    p = ctx.work / "pages.pdf"
    texts, _ = pdf_page_texts(p) if p.exists() else ([], [])
    labels = []
    for t in texts:
        m = re.search(r"Page ([A-E])\b", t)
        labels.append(m.group(1) if m else "?")
    r.subgoals["page_c_deleted"] = p.exists() and "C" not in labels
    r.subgoals["e_first"] = bool(labels) and labels[0] == "E"
    r.subgoals["exact_order"] = labels == H05_OUT
    return r


TASKS.append(Task(
    id="H05_preview_reorder_delete", tier="hard", category="native", apps=["Preview"],
    mechanics=["open_panel", "thumbnails", "drag", "delete", "save"],
    instruction="Open {work}/pages.pdf in Preview. It has five pages labelled Page A to Page E. Delete Page C, move Page E so it becomes "
                "the first page, and save the PDF in place. The final order must be E, A, B, D.",
    setup=lambda c: F.make_pdf(c.work / "pages.pdf", [f"Page {x}" for x in H05_IN], big=True), check=h05_check,
    good=lambda c: (F.make_pdf(c.work / "pages.pdf", [f"Page {x}" for x in H05_OUT], big=True), "Done.")[1],
    bad=lambda c: (F.make_pdf(c.work / "pages.pdf", [f"Page {x}" for x in ["A", "B", "D", "E"]], big=True), "Done.")[1],
))


# H06 kanban drag (localhost)
def h06_check(ctx, text):
    import json
    r = base(text)
    p = ctx.kv_dir / "kanban.json"
    st = json.loads(p.read_text()) if p.exists() else {}
    allcards = sum(st.values(), []) if st else []
    r.subgoals["fix_login_in_progress"] = "Fix login bug" in st.get("In progress", [])
    r.subgoals["write_tests_done"] = "Write tests" in st.get("Done", [])
    r.subgoals["update_docs_done"] = "Update docs" in st.get("Done", [])
    r.subgoals["others_unmoved"] = ("Design review" in st.get("To do", []) and "Refactor API" in st.get("In progress", [])
                                    and "Set up CI" in st.get("Done", []) and len(allcards) == 6)
    return r


TASKS.append(Task(
    id="H06_web_kanban_drag", tier="hard", category="web-local", apps=["browser"], mechanics=["drag", "pointer_events"],
    instruction="In the web browser, open {url}/kanban.html. Using drag and drop, move \"Fix login bug\" to In progress, and move "
                "\"Write tests\" and \"Update docs\" to Done. Leave the other cards where they are.",
    setup=lambda c: F.write_kanban(c), check=h06_check,
    good=lambda c: (F.write_kanban(c, {"To do": ["Design review"], "In progress": ["Refactor API", "Fix login bug"],
                                       "Done": ["Set up CI", "Write tests", "Update docs"]}), "Done.")[1],
    bad=lambda c: (F.write_kanban(c, {"To do": ["Design review", "Update docs"], "In progress": ["Refactor API", "Fix login bug"],
                                      "Done": ["Set up CI", "Write tests"]}), "Done.")[1],
))


# H07 web research across pages -> Numbers -> CSV
def h07_check(ctx, text):
    r = base(text)
    p = ctx.work / "prices.csv"
    r.subgoals["exported_csv"] = p.exists()
    rows = csv_rows(p) if p.exists() else []
    idx, data = find_header_table([rows], ["Product", "Price"])
    r.subgoals["headers"] = idx is not None
    ok_items, ok_total = False, False
    if idx is not None:
        got = {cell_str(row[idx["product"]]): num(row[idx["price"]]) for row in data if len(row) > max(idx.values())}
        ok_items = all(got.get(n) is not None and abs(got[n] - F.store_price(n)) < 0.006 for n in F.STORE_TARGETS)
        exp_total = round(sum(F.store_price(n) for n in F.STORE_TARGETS), 2)
        ok_total = any(k.lower().startswith("total") and v is not None and abs(v - exp_total) < 0.006 for k, v in got.items())
        if not ok_total:  # total may sit in another column of a "Total" row
            for row in data:
                if any(cell_str(c).lower().startswith("total") for c in row):
                    ok_total = any(num(c) is not None and abs(num(c) - exp_total) < 0.006 for c in row)
    r.subgoals["prices_correct"] = ok_items
    r.subgoals["total_row"] = ok_total
    return r


def h07_good(ctx, ok=True):
    rows = [["Product", "Price"]] + [[n, f"${F.store_price(n):.2f}" if ok else f"${[w for m, w, _ in F.STORE if m == n][0]:.2f}"]
                                     for n in F.STORE_TARGETS]
    rows.append(["Total", f"${sum(F.store_price(n) for n in F.STORE_TARGETS):.2f}"])
    with open(ctx.work / "prices.csv", "w", newline="") as f:
        csv.writer(f).writerows(rows)
    return "Done."


TASKS.append(Task(
    id="H07_web_research_to_csv", tier="hard", category="multi-app", apps=["browser", "Numbers"],
    mechanics=["navigate_many_pages", "read_web", "cell_entry", "formula", "export_dialog"],
    instruction="The shop at {url}/data/store.html lists products; each product's current price is on its own page (use the sale price "
                "when there is one). In Numbers, make a table with columns Product and Price for these five products: "
                + ", ".join(F.STORE_TARGETS) + ". Add a final row labelled Total with the sum of the five prices. Export it as CSV to "
                "{work}/prices.csv",
    setup=lambda c: F.write_store(c), check=h07_check, good=h07_good, bad=lambda c: h07_good(c, ok=False),
))

# H08 merge two text files sorted
H08_EXPECT = sorted(F.MERGE_A + F.MERGE_B)


def h08_check(ctx, text):
    r = base(text)
    p = ctx.work / "merged.txt"
    r.subgoals["saved"] = p.exists()
    raw = p.read_text(errors="replace") if p.exists() else ""
    r.subgoals["plain_text"] = p.exists() and not raw.startswith("{\\rtf")
    lines = [l.strip() for l in raw.split("\n") if l.strip()]
    r.subgoals["all_names"] = sorted(lines) == H08_EXPECT
    r.subgoals["sorted"] = lines == H08_EXPECT
    r.subgoals["sources_unchanged"] = ((ctx.work / "a.txt").read_text() == "\n".join(F.MERGE_A) + "\n"
                                       and (ctx.work / "b.txt").read_text() == "\n".join(F.MERGE_B) + "\n")
    return r


def h08_setup(ctx):
    (ctx.work / "a.txt").write_text("\n".join(F.MERGE_A) + "\n")
    (ctx.work / "b.txt").write_text("\n".join(F.MERGE_B) + "\n")


TASKS.append(Task(
    id="H08_textedit_merge_sort", tier="hard", category="native", apps=["TextEdit"],
    mechanics=["open_panel", "multi_window", "typing", "save_panel"],
    instruction="{work}/a.txt and {work}/b.txt each list eight names, one per line. Using TextEdit, create a new plain text file "
                "{work}/merged.txt that contains all sixteen names, one per line, sorted alphabetically. Don't modify a.txt or b.txt.",
    setup=h08_setup, check=h08_check,
    good=lambda c: ((c.work / "merged.txt").write_text("\n".join(H08_EXPECT) + "\n"), "Done.")[1],
    bad=lambda c: ((c.work / "merged.txt").write_text("\n".join(F.MERGE_A + F.MERGE_B) + "\n"), "Done.")[1],
))

# H09 Pages table -> docx
H09 = [["Name", "Role", "Office"], ["Priya Shah", "Engineer", "Toronto"], ["Marco Rossi", "Designer", "Milan"],
       ["Aiko Tanaka", "Product Manager", "Osaka"]]


def h09_check(ctx, text):
    r = base(text)
    p = ctx.work / "team.docx"
    r.subgoals["exported"] = p.exists()
    tables = []
    if p.exists():
        import docx
        d = docx.Document(str(p))
        for t in d.tables:
            tables.append([[c.text.strip() for c in row.cells] for row in t.rows])
    best = None
    for t in tables:
        if t and t[0][:3] == H09[0]:
            best = t
    r.subgoals["table_with_header"] = best is not None
    nonempty = [row for row in (best or []) if any(row)]
    r.subgoals["rows_correct"] = best is not None and [row[:3] for row in nonempty] == H09
    r.subgoals["exact_4x3"] = best is not None and len(best) == 4 and all(len(row) == 3 for row in best)
    return r


def h09_good(ctx, ok=True):
    import docx
    d = docx.Document()
    d.add_paragraph("Team")
    data = H09 if ok else H09 + [["", "", ""]]
    t = d.add_table(rows=len(data), cols=3)
    for i, row in enumerate(data):
        for j, v in enumerate(row):
            t.cell(i, j).text = v
    d.save(str(ctx.work / "team.docx"))
    return "Done."


TASKS.append(Task(
    id="H09_pages_table_docx", tier="hard", category="native", apps=["Pages"],
    mechanics=["template_chooser", "insert_table", "resize_table", "cell_entry", "export_dialog"],
    instruction="In Pages, create a new blank document containing a table with exactly 4 rows and 3 columns:\n"
                + "\n".join(" | ".join(r) for r in H09) +
                "\n(the first row is the header). Export it as a Word document to {work}/team.docx",
    setup=nothing, check=h09_check, good=h09_good, bad=lambda c: h09_good(c, ok=False),
))


# H10 invoice PDF -> Numbers -> CSV
def h10_check(ctx, text):
    r = base(text)
    p = ctx.work / "invoice.csv"
    r.subgoals["exported_csv"] = p.exists()
    rows = csv_rows(p) if p.exists() else []
    idx, data = find_header_table([rows], ["Description", "Qty", "Unit Price", "Line Total"])
    r.subgoals["headers"] = idx is not None
    ok_items, ok_lines, ok_total = False, False, False
    if idx is not None:
        got = {cell_str(row[idx["description"]]): row for row in data if len(row) > max(idx.values())}
        ok_items = all(d in got and num(got[d][idx["qty"]]) == q and abs(num(got[d][idx["unit price"]]) - u) < 0.006
                       for d, q, u in F.INVOICE)
        ok_lines = all(d in got and num(got[d][idx["line total"]]) is not None and abs(num(got[d][idx["line total"]]) - q * u) < 0.006
                       for d, q, u in F.INVOICE)
        exp = round(sum(q * u for _, q, u in F.INVOICE), 2)
        for row in data:
            if any(cell_str(c).lower().startswith("total") for c in row):
                ok_total = ok_total or any(num(c) is not None and abs(num(c) - exp) < 0.006 for c in row)
    r.subgoals["items_correct"] = ok_items
    r.subgoals["line_totals"] = ok_lines
    r.subgoals["grand_total"] = ok_total
    return r


def h10_good(ctx, ok=True):
    rows = [["Description", "Qty", "Unit Price", "Line Total"]]
    for d, q, u in F.INVOICE:
        rows.append([d, q, f"${u:,.2f}", f"${q * u:,.2f}"])
    tot = sum(q * u for _, q, u in F.INVOICE)
    rows.append(["Total", "", "", f"${tot if ok else tot - 18.99:,.2f}"])
    with open(ctx.work / "invoice.csv", "w", newline="") as f:
        csv.writer(f).writerows(rows)
    return "Done."


TASKS.append(Task(
    id="H10_pdf_invoice_to_numbers_csv", tier="hard", category="multi-app", apps=["Preview", "Numbers"],
    mechanics=["open_panel", "read_pdf", "cell_entry", "formula", "export_dialog"],
    instruction="{work}/invoice.pdf is an invoice with six line items. In Numbers, make a table with columns Description, Qty, "
                "Unit Price and Line Total (Qty × Unit Price) for every line item, plus a final row labelled Total with the sum of the "
                "line totals. Export it as CSV to {work}/invoice.csv",
    setup=lambda c: F.make_invoice_pdf(c.work / "invoice.pdf"), check=h10_check, good=h10_good, bad=lambda c: h10_good(c, ok=False),
))


# H11 file picker upload (localhost)
def h11_check(ctx, text):
    r = base(text)
    ups = ctx.web_events("upload")
    u = ups[-1] if ups else {}
    files = u.get("files", [])
    want = sha256(ctx.work / "inbox" / "receipt.png")
    r.subgoals["uploaded"] = bool(ups)
    r.subgoals["right_file"] = any(f.get("sha256") == want for f in files)
    r.subgoals["amount"] = (u.get("fields", {}).get("amount") or "").strip().lstrip("$") in ("42.50", "42.5")
    return r


def h11_write(ctx, ok=True):
    import json, time
    rec = {"kind": "upload", "files": [{"field": "receipt", "filename": "receipt.png" if ok else "chart.png", "size": 1,
                                        "sha256": sha256(ctx.work / "inbox" / ("receipt.png" if ok else "chart.png"))}],
           "fields": {"amount": "42.50"}, "t": time.time()}
    with open(ctx.web_log, "a") as f:
        f.write(json.dumps(rec) + "\n")
    return "Done."


TASKS.append(Task(
    id="H11_web_file_upload", tier="hard", category="multi-app", apps=["browser"], mechanics=["file_picker", "go_to_folder", "form"],
    instruction="In the web browser, open {url}/upload.html. Enter 42.50 as the amount, choose the file {work}/inbox/receipt.png as the "
                "receipt image, and click Upload receipt.",
    setup=lambda c: F.make_inbox(c), check=h11_check, good=h11_write, bad=lambda c: h11_write(c, ok=False),
))


# H12 download -> Finder move/rename
def h12_check(ctx, text):
    r = base(text)
    exp = "metric,value\nrevenue,48210\nnew_customers,312\nchurn_rate,0.031\n"
    dest = ctx.work / "reports" / "q3.csv"
    r.subgoals["downloaded"] = bool(ctx.web_events("download"))
    r.subgoals["in_reports_as_q3"] = dest.exists()
    r.subgoals["content_intact"] = dest.exists() and dest.read_text() == exp
    return r


def h12_setup(ctx):
    (ctx.work / "reports").mkdir(parents=True, exist_ok=True)
    F.write_reports_page(ctx)


def h12_good(ctx, ok=True):
    import json, time
    with open(ctx.web_log, "a") as f:
        f.write(json.dumps({"kind": "download", "name": "x", "t": time.time()}) + "\n")
    dest = ctx.work / "reports" / ("q3.csv" if ok else f"bcu-eval-q3-report-{ctx.lane}.csv")
    dest.write_text("metric,value\nrevenue,48210\nnew_customers,312\nchurn_rate,0.031\n")
    return "Done."


TASKS.append(Task(
    id="H12_web_download_to_finder", tier="hard", category="multi-app", apps=["browser", "Finder"],
    mechanics=["download", "go_to_folder", "move", "rename"],
    instruction="In the web browser, open {url}/data/reports.html and download the Q3 2026 report (CSV). Then, in Finder, move the "
                "downloaded file into {work}/reports and rename it q3.csv. It must not remain in Downloads.",
    setup=h12_setup, check=h12_check, good=h12_good, bad=lambda c: h12_good(c, ok=False),
))


# =====================================================================
# INFEASIBLE
# =====================================================================
def infeasible_check(extra=None):
    def check(ctx, text):
        r = base(text, feasible=False)
        r.subgoals["declined_as_infeasible"] = r.said_infeasible
        r.subgoals["no_fabricated_answer"] = r.answer is None or norm(r.answer) in ("", "none", "n/a", "infeasible")
        if extra:
            extra(ctx, r)
        return r
    return check


def i01_setup(ctx):
    F.write_numbers(ctx.work / "q3_forecast.numbers", [["Metric", "Value"], ["Revenue", 51234], ["Costs", 40211]])


TASKS.append(Task(
    id="I01_missing_file", tier="infeasible", category="infeasible", apps=["Numbers"], mechanics=["open_panel"], infeasible=True,
    instruction="Open {work}/q4_forecast.numbers in Numbers and tell me the value in cell B2.",
    setup=i01_setup, check=infeasible_check(),
    good=lambda c: "There is no q4_forecast.numbers in that folder (only q3_forecast.numbers).\nINFEASIBLE: the file does not exist.",
    bad=lambda c: "ANSWER: 51234",
))

TASKS.append(Task(
    id="I02_settings_battery", tier="infeasible", category="infeasible", apps=["System Settings"], mechanics=["navigate"], infeasible=True,
    instruction="Using System Settings (read only), tell me this Mac's battery cycle count.",
    setup=nothing, check=infeasible_check(),
    good=lambda c: "This Mac mini has no battery.\nINFEASIBLE: no battery, so there is no cycle count.",
    bad=lambda c: "ANSWER: 112",
))


def i03_extra(ctx, r):
    r.subgoals["no_submission"] = not ctx.submissions("signup")


TASKS.append(Task(
    id="I03_web_missing_field", tier="infeasible", category="infeasible", apps=["browser"], mechanics=["form"], infeasible=True,
    instruction="In the web browser, open {url}/signup.html and create an account for Grace Hopper (grace@example.org, United States, "
                "Free plan, agree to the terms) with the Referral code field set to BCU2026.",
    setup=nothing, check=infeasible_check(i03_extra),
    good=lambda c: "INFEASIBLE: the form has no Referral code field.",
    bad=lambda c: (e01_write(c, {"name": "Grace Hopper", "email": "grace@example.org", "country": "United States", "plan": "Free", "agree": "yes"}), "Done, account created.")[1],
))


def i04_extra(ctx, r):
    r.subgoals["no_fake_file"] = not any(p.suffix.lower() == ".ai" for p in ctx.work.rglob("*"))


TASKS.append(Task(
    id="I04_keynote_export_ai", tier="infeasible", category="infeasible", apps=["Keynote"], mechanics=["export_dialog"], infeasible=True,
    instruction="In Keynote, create a new presentation with one slide titled \"Logo\" and export it as an Adobe Illustrator (.ai) file "
                "to {work}/logo.ai",
    setup=nothing, check=infeasible_check(i04_extra),
    good=lambda c: "Keynote can't export Illustrator files.\nINFEASIBLE: Keynote has no .ai export.",
    bad=lambda c: ((c.work / "logo.ai").write_text("%PDF-1.4"), "Exported.")[1],
))

# fix-ups: instruction placeholders that need ctx beyond work/url
for t in TASKS:
    if t.id == "M14_notes_export_pdf":
        orig = t.instruction
        t.prompt = (lambda o: (lambda ctx: o.format(work=str(ctx.work), url=ctx.url, lane_title=m14_title(ctx))))(orig)

BY_ID = {t.id: t for t in TASKS}
