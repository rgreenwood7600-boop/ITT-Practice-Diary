import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const jspdf = require(path.join(root, "vendor/jspdf.umd.min.js"));

const context = { console, Uint8Array, Array, String, Math, Object, Error };
context.globalThis = context;
vm.runInNewContext(readFileSync(path.join(root, "js/pdf.js"), "utf8"), context);

const fonts = {
  regular: readFileSync(path.join(root, "vendor/LiberationSans-Regular.ttf")).toString("base64"),
  bold: readFileSync(path.join(root, "vendor/LiberationSans-Bold.ttf")).toString("base64")
};

function model(longText) {
  return {
    fullName: "Alex River",
    rank: "Musn",
    section: "Section 1",
    instrument: "Cornet",
    monthLabel: "November 2026",
    gradeGroups: [
      {
        title: "Training Objectives",
        items: [
          { label: "TO1.1 Perform as a military soloist \u2013 Tech Ex", grade: "A-" },
          { label: "TO1.1 Perform as a military soloist \u2013 IPE", grade: "" }
        ]
      },
      {
        title: "Values and Standards",
        items: [{ label: "Motivation", grade: "B+" }]
      },
      {
        title: "Overall Performance Grade",
        items: [{ label: "Overall Performance Grade (OPG)", grade: "B" }]
      }
    ],
    boxes: [
      { label: "Instrumental Professor", text: "Scales are settling. Keep the articulation even in the second octave.", edited: "Last edited by Ben James \u00b7 23 Nov 2026, 14:05" },
      { label: "Academic Bandmaster", text: "Theory homework is complete. Listening notes need another pass.", edited: "Last edited by Ben James \u00b7 23 Nov 2026, 14:10" },
      { label: "Section Commander", text: "Reliable in section rehearsal.", edited: "Last edited by Ben James \u00b7 20 Nov 2026, 09:15" },
      { label: "Senior Instructor", text: longText, edited: "Last edited by Ben James \u00b7 23 Nov 2026, 16:40" },
      { label: "Trainee", text: "I am working on flexibility studies and a short cornet solo.", edited: "Last edited by Alex River \u00b7 22 Nov 2026, 18:02" }
    ]
  };
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const shortDoc = context.ITTPdf.buildDiaryPdf(jspdf.jsPDF, fonts, model(""));
assert(shortDoc.getNumberOfPages() === 1, `A short diary should be one page, got ${shortDoc.getNumberOfPages()}`);
assert(Math.abs(shortDoc.internal.pageSize.getWidth() - 210) < 0.1, "Page width is not A4");
assert(Math.abs(shortDoc.internal.pageSize.getHeight() - 297) < 0.1, "Page height is not A4");

const paragraph = "Practice this week has been on long notes, scales and a study. ".repeat(80);
const longDoc = context.ITTPdf.buildDiaryPdf(jspdf.jsPDF, fonts, model(paragraph));
assert(longDoc.getNumberOfPages() >= 2, `Long text should flow onto a second page, got ${longDoc.getNumberOfPages()}`);

const output = longDoc.output();
assert(output.startsWith("%PDF"), "Output is not a PDF");

const outDir = path.join(root, "tests/output");
mkdirSync(outDir, { recursive: true });
const longPath = path.join(outDir, "sample-practice-diary.pdf");
writeFileSync(longPath, Buffer.from(longDoc.output("arraybuffer")));
writeFileSync(path.join(outDir, "sample-practice-diary-short.pdf"), Buffer.from(shortDoc.output("arraybuffer")));

const text = execFileSync("pdftotext", ["-layout", longPath, "-"], { encoding: "utf8" });
for (const phrase of [
  "Alex River",
  "Musn",
  "Section 1",
  "Cornet",
  "November 2026",
  "Instrumental Professor",
  "Academic Bandmaster",
  "Section Commander",
  "Senior Instructor",
  "Trainee",
  "Training Objectives",
  "TO1.1 Perform as a military soloist",
  "Tech Ex",
  "Values and Standards",
  "Motivation",
  "Overall Performance Grade",
  "Scales are settling",
  "Page 1 of"
]) {
  assert(text.includes(phrase), `PDF text is missing ${phrase}`);
}
assert(text.includes("Page 2 of"), "The second page has no page number");
const shortText = execFileSync("pdftotext", ["-layout", path.join(outDir, "sample-practice-diary-short.pdf"), "-"], { encoding: "utf8" });
assert(shortText.includes("No comments recorded."), "An empty box should say that nothing was recorded");
console.log(`PDF checks passed (${longDoc.getNumberOfPages()} pages for the long diary)`);
