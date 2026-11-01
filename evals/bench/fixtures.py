"""Fixture builders: deterministic data and files for the tasks."""
import csv
import json
import random
from pathlib import Path

from .common import Ctx, set_finder_tags

# ---------- data ----------
INBOX_FILES = (
    [f"export_{n}.csv" for n in ("jan", "feb", "mar", "apr", "may", "jun")]
    + [f"{n}.pdf" for n in ("invoice_1182", "contract_draft", "slides_q2", "receipt_0931")]
    + [f"{n}.txt" for n in ("todo", "abstract", "phone_numbers")]
    + ["chart.png", "receipt.png"]
    + ["README.md", "CHANGELOG.md"]
)

ABSTRACT = ("We study how small teams adopt background automation in daily office work. "
            "Across six weeks, fourteen participants delegated routine document and spreadsheet "
            "chores to an assistant that worked in hidden windows. Participants kept full control "
            "of their screens, reported fewer interruptions, and recovered about forty minutes a day.")

LETTER_PARAS = [
    "Partnership Proposal",
    "Dear Ms. Alvarez,",
    "Thank you for meeting with us last week. Acme Corp is excited about the chance to work with your team on the spring launch.",
    "As discussed, Acme Corp will provide design support, and our engineers will join your weekly planning calls. "
    "Acme Corp can start as early as January 12.",
    "Please let us know if you have questions. We look forward to hearing from you.",
    "Sincerely,",
    "Jamie Chen, Acme Corp",
]


def rtf_escape(s):
    return s.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")


def write_rtf(path, paras, bold_first=False, first_size=None):
    out = ["{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822",
           "{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;\\f1\\fswiss\\fcharset0 Helvetica-Bold;}",
           "{\\colortbl;\\red255\\green255\\blue255;}",
           "\\paperw11900\\paperh16840\\margl1440\\margr1440\\vieww11520\\viewh8400\\viewkind0",
           "\\pard\\tx720\\tx1440\\tx2160\\tx2880\\pardirnatural\\partightenfactor0", ""]
    body = []
    for i, p in enumerate(paras):
        if i == 0 and (bold_first or first_size):
            size = first_size or 24
            f = "\\f1\\b" if bold_first else "\\f0"
            body.append(f"{f}\\fs{size} \\cf0 {rtf_escape(p)}\\" + "\n" + ("\\f0\\b0" if bold_first else "") + "\\fs24 ")
        else:
            prefix = "\\f0\\fs24 \\cf0 " if i == 0 else ""
            body.append(prefix + rtf_escape(p) + ("\\" if i < len(paras) - 1 else "") + "\n")
    Path(path).write_text("\n".join(out) + "".join(body) + "}")


def inventory_rows():
    rng = random.Random(7)
    cats = ["Garden", "Kitchen", "Office", "Outdoor", "Bath"]
    names = ["Trowel", "Hose reel", "Pruner", "Seed tray", "Watering can", "Kneeler", "Rake", "Planter",
             "Colander", "Whisk", "Ladle", "Grater", "Stapler", "Desk lamp", "Notebook", "Monitor arm",
             "Tent stake", "Lantern", "Cooler", "Hammock", "Bath mat", "Towel rail", "Soap dish", "Shower caddy",
             "Spade", "Garden twine", "Plant labels", "Hand fork", "Mixing bowl", "Peeler", "Paper tray",
             "Label maker", "Camp chair", "Bug net", "Loofah", "Toothbrush cup", "Leaf blower", "Compost bin",
             "Cutting board", "Pen cup"]
    catmap = {}
    for i, n in enumerate(names):
        catmap[n] = cats[i // 8] if i < 24 else ["Garden", "Garden", "Garden", "Garden", "Kitchen", "Kitchen",
                                                 "Office", "Office", "Outdoor", "Outdoor", "Bath", "Bath",
                                                 "Garden", "Garden", "Kitchen", "Office"][i - 24]
    rows = []
    for n in names:
        rows.append({"Product": n, "Category": catmap[n], "Price": round(rng.uniform(4, 90), 2),
                     "Stock": rng.randint(0, 250)})
    rng.shuffle(rows)
    # make the cheapest garden item unique and not first
    garden = [r for r in rows if r["Category"] == "Garden"]
    cheapest = min(garden, key=lambda r: r["Price"])
    for r in garden:
        if r is not cheapest and abs(r["Price"] - cheapest["Price"]) < 0.5:
            r["Price"] = round(r["Price"] + 1.0, 2)
    return rows


CITIES = [("Port Alder", 184230, 92.4), ("Vexley", 92815, 38.7), ("North Calloway", 412907, 211.3),
          ("Brindle Bay", 57340, 21.9), ("Esterhaven", 268114, 140.6), ("Quill Harbor", 33021, 12.5),
          ("Marrowfield", 145776, 66.2), ("Tamsin Falls", 76450, 49.8)]

STORE = [("Aero Desk Fan", 39.99, 34.99), ("Birch Bookend Set", 24.50, None), ("Cobalt Water Bottle", 18.00, 14.40),
         ("Dune Throw Blanket", 59.00, None), ("Ember Candle Trio", 32.00, 27.20), ("Fjord Ceramic Mug", 14.75, None),
         ("Grove Desk Plant", 22.00, None), ("Harbor Tote Bag", 45.00, 38.25), ("Iris Notebook", 9.50, None),
         ("Juniper Diffuser", 49.00, 41.65), ("Kestrel Headphones", 129.00, None), ("Linden Wall Clock", 64.00, 54.40)]
STORE_TARGETS = ["Cobalt Water Bottle", "Fjord Ceramic Mug", "Harbor Tote Bag", "Juniper Diffuser", "Linden Wall Clock"]

INVOICE = [("Website hosting (annual)", 1, 240.00), ("Logo redesign", 1, 650.00), ("Stock photos", 12, 8.50),
           ("Copywriting (hours)", 6, 72.00), ("Domain renewal", 2, 18.99), ("Print flyers (box)", 3, 44.25)]

BUDGET_CATS = ["Rent", "Groceries", "Travel", "Utilities", "Dining", "Insurance"]
BUDGET_MONTHS = ["January", "February", "March", "April", "May", "June"]


def budget_values():
    rng = random.Random(11)
    return {c: [round(rng.uniform(40, 1800), 2) for _ in BUDGET_MONTHS] for c in BUDGET_CATS}


SALES = [("North", 12400, 13950, 15100, 16820), ("South", 9800, 10450, 9900, 11230), ("East", 15300, 14800, 16250, 17940),
         ("West", 11200, 12650, 13400, 12980), ("Central", 8700, 9150, 9600, 10340), ("Online", 21500, 24300, 26800, 31150)]

INVENTORY_CSV = [("Item", "SKU", "Quantity", "Location"),
                 ("Copper wire", "CW-110", 340, "Aisle 3"), ("Hex bolts", "HB-220", 1250, "Aisle 1"),
                 ("Wood glue", "WG-031", 58, "Aisle 7"), ("Sandpaper", "SP-400", 610, "Aisle 7"),
                 ("Cable ties", "CT-150", 2200, "Aisle 2"), ("Drill bits", "DB-008", 145, "Aisle 4"),
                 ("Paint rollers", "PR-090", 77, "Aisle 6"), ("Wall anchors", "WA-012", 980, "Aisle 1"),
                 ("Tape measure", "TM-025", 33, "Aisle 5"), ("Work gloves", "WG-777", 410, "Aisle 8"),
                 ("Safety goggles", "SG-301", 96, "Aisle 8"), ("Zip bags", "ZB-500", 1500, "Aisle 2")]

MERGE_A = ["Olivia", "Mateo", "Harper", "Kenji", "Amara", "Lucas", "Zoe", "Ibrahim"]
MERGE_B = ["Nora", "Diego", "Freya", "Caleb", "Yusuf", "Elena", "Bruno", "Sienna"]

DECK_IN = ["Intro", "Results", "DRAFT - do not present", "Method", "Conclusion", "Questions"]
DECK_OUT = ["Intro", "Method", "Results", "Conclusion", "Questions"]

REPORT_HEADINGS = ["Copper Lantern", "Quiet Harbor", "Velvet Compass", "Amber Signal", "Northern Ledger"]


# ---------- file builders ----------
def make_inbox(ctx: Ctx):
    inbox = ctx.work / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    for name in INBOX_FILES:
        p = inbox / name
        if name.endswith(".pdf"):
            make_pdf(p, [f"Document {name}"])
        elif name.endswith(".png"):
            make_png(p, name)
        elif name == "abstract.txt":
            p.write_text(ABSTRACT + "\n")
        elif name.endswith(".csv"):
            p.write_text("date,amount\n2026-01-01,10\n")
        else:
            p.write_text(f"{name}\n")
    return inbox


def make_png(p, label, size=(320, 200), color=(240, 240, 230)):
    from PIL import Image, ImageDraw
    im = Image.new("RGB", size, color)
    d = ImageDraw.Draw(im)
    d.text((12, 12), label, fill=(20, 20, 20))
    d.rectangle([10, 60, size[0] - 10, size[1] - 10], outline=(80, 80, 200), width=3)
    im.save(p)


def make_jpg(p, label, color):
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (400, 300), color)
    ImageDraw.Draw(im).text((10, 10), label, fill=(255, 255, 255))
    im.save(p, "JPEG", quality=80)


def make_pdf(p, pages, big=False):
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas
    c = canvas.Canvas(str(p), pagesize=letter)
    for text in pages:
        lines = text.split("\n")
        c.setFont("Helvetica-Bold", 40 if big else 20)
        c.drawString(72, 680, lines[0])
        c.setFont("Helvetica", 12)
        y = 640
        for l in lines[1:]:
            c.drawString(72, y, l)
            y -= 18
        c.showPage()
    c.save()


def make_invoice_pdf(p):
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas
    c = canvas.Canvas(str(p), pagesize=letter)
    c.setFont("Helvetica-Bold", 22)
    c.drawString(72, 700, "INVOICE #2026-0418")
    c.setFont("Helvetica", 11)
    c.drawString(72, 675, "Bright Pixel Studio  ·  Billed to: Lakeside Bakery  ·  Due: 30 November 2026")
    y = 630
    c.setFont("Helvetica-Bold", 11)
    for x, h in ((72, "Description"), (330, "Qty"), (400, "Unit price")):
        c.drawString(x, y, h)
    c.setFont("Helvetica", 11)
    for desc, q, u in INVOICE:
        y -= 22
        c.drawString(72, y, desc)
        c.drawString(330, y, str(q))
        c.drawString(400, y, f"${u:,.2f}")
    c.showPage()
    c.save()


def make_docx_memo(p):
    import docx
    d = docx.Document()
    d.add_paragraph("Draft Memo", style="Title")
    d.add_paragraph("To: Product team")
    d.add_paragraph("The launch checklist is complete except for the final accessibility review.")
    d.add_paragraph("We will hold the go/no-go meeting on Friday at 2 PM in Room 4B.")
    d.save(str(p))


MEMO_BODY = ["To: Product team",
             "The launch checklist is complete except for the final accessibility review.",
             "We will hold the go/no-go meeting on Friday at 2 PM in Room 4B."]


def make_sales_xlsx(p):
    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Sales"
    ws.append(["Region", "Q1", "Q2", "Q3", "Q4"])
    for r in SALES:
        ws.append(list(r))
    wb.save(str(p))


def make_deck_pptx(p, titles):
    from pptx import Presentation
    prs = Presentation()
    for t in titles:
        s = prs.slides.add_slide(prs.slide_layouts[1])
        s.shapes.title.text = t
        s.placeholders[1].text = f"Notes for {t.lower()}"
    prs.save(str(p))


def make_budget_numbers(p):
    from numbers_parser import Document
    doc = Document(num_header_rows=1, num_header_cols=1, num_rows=len(BUDGET_CATS) + 1, num_cols=len(BUDGET_MONTHS) + 1)
    t = doc.sheets[0].tables[0]
    vals = budget_values()
    t.write(0, 0, "Category")
    for j, m in enumerate(BUDGET_MONTHS):
        t.write(0, j + 1, m)
    for i, c in enumerate(BUDGET_CATS):
        t.write(i + 1, 0, c)
        for j, v in enumerate(vals[c]):
            t.write(i + 1, j + 1, v)
    doc.save(str(p))


def write_numbers(p, rows):
    from numbers_parser import Document
    doc = Document(num_header_rows=1, num_header_cols=0, num_rows=len(rows), num_cols=max(len(r) for r in rows))
    t = doc.sheets[0].tables[0]
    for i, r in enumerate(rows):
        for j, v in enumerate(r):
            t.write(i, j, v)
    doc.save(str(p))


def write_inventory_csv(p):
    with open(p, "w", newline="") as f:
        w = csv.writer(f)
        for r in INVENTORY_CSV:
            w.writerow(r)


def photos(ctx: Ctx):
    d = ctx.work / "photos"
    d.mkdir(parents=True, exist_ok=True)
    cols = [(200, 60, 60), (60, 160, 90), (50, 90, 200), (210, 160, 40), (120, 60, 160), (40, 140, 160)]
    for i, n in enumerate(range(40, 46)):
        make_jpg(d / f"IMG_00{n}.jpg", f"IMG_00{n}", cols[i])
    return d


# ---------- web data pages ----------
def page(title, body):
    return (f"<!doctype html><html><head><meta charset='utf-8'><title>{title}</title>"
            f"<link rel='stylesheet' href='/style.css'></head><body>{body}</body></html>")


def write_inventory_page(ctx: Ctx):
    rows = inventory_rows()
    trs = "".join(f"<tr><td>{r['Product']}</td><td>{r['Category']}</td><td>${r['Price']:.2f}</td><td>{r['Stock']}</td></tr>"
                  for r in rows)
    (ctx.data_dir / "inventory.html").write_text(page("Warehouse inventory",
        "<h1>Warehouse inventory</h1><table><thead><tr><th>Product</th><th>Category</th><th>Price</th><th>Stock</th></tr></thead>"
        f"<tbody>{trs}</tbody></table>"))
    return rows


def write_cities_page(ctx: Ctx):
    trs = "".join(f"<tr><td>{c}</td><td>{p:,}</td><td>{a}</td></tr>" for c, p, a in CITIES)
    (ctx.data_dir / "cities.html").write_text(page("Regional city statistics",
        "<h1>Regional city statistics</h1><p>Population from the 2025 census. Area in square kilometres.</p>"
        "<table><thead><tr><th>City</th><th>Population</th><th>Area (km²)</th></tr></thead>"
        f"<tbody>{trs}</tbody></table>"))


def store_slug(name):
    return name.lower().replace(" ", "-")


def write_store(ctx: Ctx):
    items = "".join(f"<li><a href='/data/store-{store_slug(n)}.html'>{n}</a></li>" for n, _, _ in STORE)
    (ctx.data_dir / "store.html").write_text(page("Larkspur Home – Shop", f"<h1>Larkspur Home</h1><p>Our products:</p><ul>{items}</ul>"))
    for n, was, now in STORE:
        price = (f"<p class='price'><s>${was:.2f}</s> <b>Now ${now:.2f}</b> (sale)</p>" if now
                 else f"<p class='price'><b>${was:.2f}</b></p>")
        (ctx.data_dir / f"store-{store_slug(n)}.html").write_text(page(f"{n} – Larkspur Home",
            f"<p><a href='/data/store.html'>← All products</a></p><h1>{n}</h1>{price}"
            "<p>Free shipping on orders over $75. Ships in 2–3 business days.</p>"))


def store_price(name):
    for n, was, now in STORE:
        if n == name:
            return now if now else was


def write_reports_page(ctx: Ctx):
    name = f"bcu-eval-q3-report-{ctx.lane}.csv"
    content = "metric,value\nrevenue,48210\nnew_customers,312\nchurn_rate,0.031\n"
    (ctx.data_dir / name).write_text(content)
    (ctx.data_dir / "reports.html").write_text(page("Quarterly reports",
        f"<h1>Quarterly reports</h1><ul><li><a href='/download/{name}'>Download Q3 2026 report (CSV)</a></li></ul>"))
    return name, content


def kanban_initial():
    return {"To do": ["Write tests", "Update docs", "Fix login bug", "Design review"],
            "In progress": ["Refactor API"], "Done": ["Set up CI"]}


def write_kanban(ctx: Ctx, state=None):
    (ctx.kv_dir / "kanban.json").write_text(json.dumps(state or kanban_initial()))
