/* Client-side A4 diary. Nothing is uploaded. Liberation Sans is vendored. */
(function (root) {
  var NAVY = [0, 33, 71];
  var GOLD = [185, 151, 91];
  var INK = [28, 36, 48];
  var MUTED = [62, 76, 90];
  var PAGE_W = 210;
  var PAGE_H = 297;
  var MARGIN_X = 16;
  var CONTENT_BOTTOM = 278;
  var FOOTER_Y = 288;

  function filename(model) {
    var who = String(model.fullName || "trainee")
      .replace(/[^A-Za-z0-9]+/g, "-")
      .replace(/^-|-$/g, "") || "trainee";
    var month = String(model.monthLabel || "month").replace(/\s+/g, "-");
    return "RMSM-ITT-Practice-Diary-" + who + "-" + month + ".pdf";
  }

  function buildDiaryPdf(JsPDF, fonts, model) {
    var doc = new JsPDF({ unit: "mm", format: "a4", compress: true });
    doc.addFileToVFS("LiberationSans-Regular.ttf", fonts.regular);
    doc.addFont("LiberationSans-Regular.ttf", "LiberationSans", "normal");
    doc.addFileToVFS("LiberationSans-Bold.ttf", fonts.bold);
    doc.addFont("LiberationSans-Bold.ttf", "LiberationSans", "bold");

    var title = "RMSM ITT Practice Diary \u2013 " + model.monthLabel;
    doc.setProperties({
      title: title,
      subject: "Initial Trade Training practice diary",
      author: "Royal Military School of Music",
      creator: "RMSM ITT Practice Diary"
    });

    var y = 0;
    var page = 1;

    function text(value, x, baseline, options) {
      doc.text(String(value), x, baseline, options || {});
    }

    function rule(yPos, colour, weight) {
      doc.setDrawColor(colour[0], colour[1], colour[2]);
      doc.setLineWidth(weight);
      doc.line(MARGIN_X, yPos, PAGE_W - MARGIN_X, yPos);
    }

    function chrome(first) {
      doc.setFillColor(NAVY[0], NAVY[1], NAVY[2]);
      doc.rect(0, 0, PAGE_W, first ? 12 : 10, "F");
      doc.setFillColor(GOLD[0], GOLD[1], GOLD[2]);
      doc.rect(0, first ? 12 : 10, PAGE_W, 1.5, "F");
      doc.setFont("LiberationSans", "bold");
      doc.setFontSize(9);
      doc.setTextColor(255, 255, 255);
      text("THE ROYAL MILITARY SCHOOL OF MUSIC", MARGIN_X, first ? 7.6 : 6.5);
      if (!first) {
        doc.setFont("LiberationSans", "normal");
        text(model.monthLabel, PAGE_W - MARGIN_X, 6.5, { align: "right" });
      }
      y = first ? 22 : 18;
    }

    function newPage() {
      doc.addPage();
      page += 1;
      chrome(false);
    }

    function ensure(height) {
      if (y + height > CONTENT_BOTTOM) newPage();
    }

    function pairHeight(value, width) {
      doc.setFont("LiberationSans", "normal");
      doc.setFontSize(12);
      var lines = doc.splitTextToSize(value || "\u2014", width);
      return 6 + lines.length * 5;
    }

    function drawPair(label, value, x, width) {
      doc.setFont("LiberationSans", "bold");
      doc.setFontSize(8);
      doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
      text(label.toUpperCase(), x, y);
      doc.setFont("LiberationSans", "normal");
      doc.setFontSize(12);
      doc.setTextColor(NAVY[0], NAVY[1], NAVY[2]);
      var lines = doc.splitTextToSize(value || "\u2014", width);
      doc.text(lines, x, y + 5.5);
    }

    chrome(true);

    doc.setFont("LiberationSans", "bold");
    doc.setFontSize(16);
    doc.setTextColor(NAVY[0], NAVY[1], NAVY[2]);
    var titleLines = doc.splitTextToSize(title, PAGE_W - MARGIN_X * 2);
    doc.text(titleLines, MARGIN_X, y);
    y += titleLines.length * 7 + 1;

    doc.setFont("LiberationSans", "normal");
    doc.setFontSize(11);
    doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
    text("Initial Trade Training \u00b7 Portsmouth", MARGIN_X, y);
    y += 4;
    rule(y, GOLD, 0.6);
    y += 8;

    var colW = (PAGE_W - MARGIN_X * 2 - 8) / 2;
    var left = [
      ["Name", model.fullName],
      ["Section", model.section]
    ];
    var right = [
      ["Rank", model.rank],
      ["Instrument", model.instrument]
    ];
    for (var i = 0; i < left.length; i += 1) {
      var rowH = Math.max(
        pairHeight(left[i][1], colW),
        pairHeight(right[i][1], colW)
      );
      ensure(rowH + 2);
      var rowY = y;
      drawPair(left[i][0], left[i][1], MARGIN_X, colW);
      y = rowY;
      drawPair(right[i][0], right[i][1], MARGIN_X + colW + 8, colW);
      y = rowY + rowH + 2;
    }

    y += 2;
    rule(y, NAVY, 0.3);
    y += 8;

    (model.boxes || []).forEach(function (box) {
      var body = box.text && String(box.text).trim()
        ? String(box.text).replace(/\r\n/g, "\n")
        : "";
      var empty = body === "";
      doc.setFont("LiberationSans", empty ? "normal" : "normal");
      doc.setFontSize(11);
      var paragraphs = empty ? ["No comments recorded."] : body.split("\n");
      var wrapped = [];
      paragraphs.forEach(function (paragraph) {
        if (paragraph === "") {
          wrapped.push("");
          return;
        }
        doc.splitTextToSize(paragraph, PAGE_W - MARGIN_X * 2).forEach(function (line) {
          wrapped.push(line);
        });
      });

      ensure(24);
      doc.setFont("LiberationSans", "bold");
      doc.setFontSize(12);
      doc.setTextColor(NAVY[0], NAVY[1], NAVY[2]);
      text(box.label, MARGIN_X, y);
      y += 5;
      doc.setFont("LiberationSans", "normal");
      doc.setFontSize(9);
      doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
      text(box.edited || "Not yet edited", MARGIN_X, y);
      y += 6;

      doc.setFont("LiberationSans", empty ? "normal" : "normal");
      doc.setFontSize(11);
      if (empty) doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
      else doc.setTextColor(INK[0], INK[1], INK[2]);

      var continued = false;
      wrapped.forEach(function (line) {
        if (y + 5 > CONTENT_BOTTOM) {
          newPage();
          doc.setFont("LiberationSans", "bold");
          doc.setFontSize(11);
          doc.setTextColor(NAVY[0], NAVY[1], NAVY[2]);
          text(box.label + " (continued)", MARGIN_X, y);
          y += 6;
          doc.setFont("LiberationSans", "normal");
          doc.setFontSize(11);
          doc.setTextColor(empty ? MUTED[0] : INK[0], empty ? MUTED[1] : INK[1], empty ? MUTED[2] : INK[2]);
          continued = true;
        }
        if (line !== "") text(line, MARGIN_X, y);
        y += 5;
        if (continued) continued = false;
      });
      y += 6;
    });

    var total = doc.getNumberOfPages();
    for (var n = 1; n <= total; n += 1) {
      doc.setPage(n);
      doc.setFont("LiberationSans", "normal");
      doc.setFontSize(8);
      doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
      text("Royal Military School of Music \u00b7 ITT Practice Diary", MARGIN_X, FOOTER_Y);
      text("Page " + n + " of " + total, PAGE_W - MARGIN_X, FOOTER_Y, { align: "right" });
    }

    return doc;
  }

  var fontCache = null;

  function bytesToBase64(bytes) {
    var binary = "";
    var chunk = 0x8000;
    for (var i = 0; i < bytes.length; i += chunk) {
      var slice = bytes.subarray(i, i + chunk);
      for (var j = 0; j < slice.length; j += 1) binary += String.fromCharCode(slice[j]);
    }
    return root.btoa(binary);
  }

  async function loadFonts() {
    if (fontCache) return fontCache;
    var regular = await fetch("vendor/LiberationSans-Regular.ttf");
    var bold = await fetch("vendor/LiberationSans-Bold.ttf");
    if (!regular.ok || !bold.ok) throw new Error("The PDF fonts could not be loaded.");
    fontCache = {
      regular: bytesToBase64(new Uint8Array(await regular.arrayBuffer())),
      bold: bytesToBase64(new Uint8Array(await bold.arrayBuffer()))
    };
    return fontCache;
  }

  async function downloadDiaryPdf(model) {
    var fonts = await loadFonts();
    var JsPDF = root.jspdf && root.jspdf.jsPDF;
    if (!JsPDF) throw new Error("PDF support did not load.");
    buildDiaryPdf(JsPDF, fonts, model).save(filename(model));
  }

  root.ITTPdf = {
    buildDiaryPdf: buildDiaryPdf,
    downloadDiaryPdf: downloadDiaryPdf,
    filename: filename
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
