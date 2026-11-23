(function () {
  var BOXES = [
    { type: "instrumental_professor", label: "Instrumental Professor", staff: true },
    { type: "academic_bandmaster", label: "Academic Bandmaster", staff: true },
    { type: "section_commander", label: "Section Commander", staff: true },
    { type: "senior_instructor", label: "Senior Instructor", staff: true },
    { type: "trainee", label: "Trainee", staff: false }
  ];

  var state = {
    client: null,
    session: null,
    me: null,
    sections: [],
    trainees: [],
    diary: null
  };

  function $(id) {
    return document.getElementById(id);
  }

  function announce(message) {
    $("status").textContent = message || "";
  }

  function showError(el, message) {
    el.hidden = !message;
    el.textContent = message || "";
  }

  function friendlyError(error) {
    var msg = (error && error.message) || "Something went wrong.";
    if (/failed to fetch|networkerror|load failed/i.test(msg)) {
      return "The diary could not be reached. Check the connection and try again.";
    }
    if (/invalid login/i.test(msg)) return "Username or password is not recognised.";
    if (/already registered|already been registered|username is reserved|could not be registered/i.test(msg)) {
      return "That username is already taken. Choose another, or log in.";
    }
    if (/3 to 30 letters/i.test(msg)) return "Use 3 to 30 letters and numbers, starting with a letter.";
    if (/row-level security|permission denied/i.test(msg)) return "You do not have permission to do that.";
    if (/future months/i.test(msg)) return "Future months are not open yet.";
    if (/jwt|not authenticated|session/i.test(msg) && /invalid|expired|ended/i.test(msg)) {
      return "Your session has ended. Log in again.";
    }
    return msg;
  }

  function configProblem() {
    var c = window.ITT_CONFIG;
    if (!c || typeof c.supabaseUrl !== "string" || typeof c.supabaseAnonKey !== "string") {
      return "placeholder";
    }
    if (c.supabaseUrl.indexOf("YOUR_PROJECT") !== -1 || c.supabaseAnonKey.indexOf("YOUR_SUPABASE") !== -1) {
      return "placeholder";
    }
    if (!/^https?:\/\//.test(c.supabaseUrl)) return "The Supabase URL in config.js is not valid.";
    return "";
  }

  function londonMonth(date) {
    var parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: "Europe/London",
      year: "numeric",
      month: "2-digit"
    }).formatToParts(date || new Date());
    var get = function (type) {
      return parts.find(function (part) { return part.type === type; }).value;
    };
    return { year: Number(get("year")), month: Number(get("month")) };
  }

  function monthValue(year, month) {
    return year + "-" + String(month).padStart(2, "0");
  }

  function parseMonth(value) {
    var bits = String(value || "").split("-");
    return { year: Number(bits[0]), month: Number(bits[1]) };
  }

  function shiftMonth(year, month, delta) {
    var date = new Date(Date.UTC(year, month - 1 + delta, 1));
    return { year: date.getUTCFullYear(), month: date.getUTCMonth() + 1 };
  }

  function monthLabel(year, month) {
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: "UTC",
      month: "long",
      year: "numeric"
    }).format(new Date(Date.UTC(year, month - 1, 1)));
  }

  function formatWhen(iso) {
    if (!iso) return "";
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: "Europe/London",
      dateStyle: "medium",
      timeStyle: "short"
    }).format(new Date(iso));
  }

  var STAFF_USERNAME = "ittstaff";
  var STAFF_EMAIL = "ittstaff@staff.itt-diary.invalid";

  function normaliseUsername(value) {
    return String(value || "").trim().toLowerCase();
  }

  function usernameProblem(username) {
    if (!/^[a-z][a-z0-9]{2,29}$/.test(username)) {
      return "Use 3 to 30 letters and numbers, starting with a letter.";
    }
    if (username === STAFF_USERNAME) return "That username is reserved.";
    return "";
  }

  function loginEmailFor(username, staffMode) {
    if (staffMode) return username === STAFF_USERNAME ? STAFF_EMAIL : "";
    if (usernameProblem(username)) return "";
    return username + "@trainee.itt-diary.invalid";
  }

  function editorName(name) {
    if (!name || name === "New account" || name === "Unknown") return "Staff";
    return name;
  }

  function editedLine(comment) {
    if (!comment || !comment.last_edited_at) return "Not yet edited";
    return "Last edited by " + editorName(comment.last_edited_name) + " \u00b7 " + formatWhen(comment.last_edited_at);
  }

  function sectionName(id) {
    var found = state.sections.find(function (section) { return section.id === id; });
    return found ? found.name : "";
  }

  function showView(id) {
    document.querySelectorAll(".view").forEach(function (view) {
      view.hidden = view.id !== id;
    });
    $("booting").hidden = true;
    var shown = $(id);
    var title = shown.dataset.title || "";
    document.title = title ? title + " \u00b7 RMSM ITT Practice Diary" : "RMSM ITT Practice Diary";
    $("main").focus({ preventScroll: true });
  }

  function setSessionBar() {
    var bar = $("sessionBar");
    if (!state.me) {
      bar.hidden = true;
      $("sessionWho").textContent = "";
      return;
    }
    bar.hidden = false;
    if (state.me.is_staff) {
      $("sessionWho").textContent = editorName(state.me.full_name);
      return;
    }
    var bits = [state.me.full_name];
    if (sectionName(state.me.section_id)) bits.push(sectionName(state.me.section_id));
    $("sessionWho").textContent = bits.join(" \u00b7 ");
  }

  function fillSelect(select, options) {
    var selected = options.selected || "";
    var blank = options.blank;
    select.replaceChildren();
    if (blank) {
      var empty = document.createElement("option");
      empty.value = "";
      empty.textContent = blank;
      select.append(empty);
    }
    state.sections.forEach(function (section) {
      var option = document.createElement("option");
      option.value = section.id;
      option.textContent = section.name;
      if (section.id === selected) option.selected = true;
      select.append(option);
    });
  }

  async function loadSections() {
    var result = await state.client
      .from("sections")
      .select("id, name, sort_order")
      .order("sort_order")
      .order("name");
    if (result.error) throw result.error;
    state.sections = result.data || [];
  }

  function currentRoute() {
    var raw = decodeURIComponent(location.hash.replace(/^#/, ""));
    if (raw.indexOf("access_token=") !== -1) return { name: "callback" };
    if (raw === "" || raw === "home") return { name: "home" };
    if (raw === "login" || raw === "staff-login") return { name: "login", staff: raw === "staff-login" };
    if (raw === "register") return { name: "register" };
    if (raw === "diary") return { name: "diary" };
    if (raw === "staff") return { name: "staff" };
    var match = raw.match(/^staff\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i);
    if (match) return { name: "staff-diary", id: match[1] };
    return { name: "missing" };
  }

  async function loadMe() {
    var result = await state.client
      .from("profiles")
      .select("id, full_name, rank, section_id, instrument, username, is_staff")
      .eq("id", state.session.user.id)
      .single();
    if (result.error) throw result.error;
    state.me = result.data;
    return state.me;
  }

  function homeHash() {
    return state.me && state.me.is_staff ? "#staff" : "#diary";
  }

  async function ensureSession() {
    if (state.session) return true;
    var existing = await state.client.auth.getSession();
    state.session = existing.data.session;
    return Boolean(state.session);
  }

  var routing = false;
  var routeQueued = false;

  async function route() {
    if (routing) {
      routeQueued = true;
      return;
    }
    routing = true;
    try {
      do {
        routeQueued = false;
        await routeOnce();
      } while (routeQueued);
    } finally {
      routing = false;
    }
  }

  async function routeOnce() {
    try {
      var problem = configProblem();
      if (problem) {
        showView("viewSetup");
        $("sessionBar").hidden = true;
        return;
      }
      var where = currentRoute();
      if (where.name === "callback") return;

      var signedIn = await ensureSession();
      if (signedIn && !state.me) {
        try {
          await loadSections();
          await loadMe();
        } catch (error) {
          state.me = null;
          showView("viewMissing");
          $("missingText").textContent = friendlyError(error);
          return;
        }
      }
      if (!signedIn) state.me = null;
      setSessionBar();

      if (!signedIn && (where.name === "diary" || where.name === "staff" || where.name === "staff-diary")) {
        location.hash = "#login";
        return;
      }

      if (where.name === "home") {
        if (signedIn) {
          location.hash = homeHash();
          return;
        }
        showView("viewLanding");
        return;
      }

      if (where.name === "login") {
        if (signedIn) {
          location.hash = homeHash();
          return;
        }
        await showLogin(where.staff);
        return;
      }

      if (where.name === "register") {
        if (signedIn) {
          location.hash = homeHash();
          return;
        }
        await showRegister();
        return;
      }

      if (where.name === "diary") {
        if (state.me.is_staff) {
          location.hash = "#staff";
          return;
        }
        await openDiary(state.me.id);
        return;
      }

      if (where.name === "staff") {
        if (!state.me.is_staff) {
          location.hash = "#diary";
          return;
        }
        await showStaff();
        return;
      }

      if (where.name === "staff-diary") {
        if (!state.me.is_staff) {
          location.hash = "#diary";
          return;
        }
        await openDiary(where.id);
        return;
      }

      showView("viewMissing");
      $("missingText").textContent = "That page is not part of the diary.";
    } catch (error) {
      showView("viewMissing");
      $("missingText").textContent = friendlyError(error);
    }
  }

  async function showLogin(staff) {
    showError($("loginError"), "");
    $("loginForm").dataset.mode = staff ? "staff" : "trainee";
    $("loginHeading").textContent = staff ? "Staff log in" : "Log in";
    $("loginLead").textContent = staff
      ? "Use the shared staff username and password. Staff registration is not available."
      : "Sign in with your username and password.";
    $("loginUsername").required = true;
    $("loginRegisterWrap").hidden = staff;
    $("loginStaffWrap").hidden = staff;
    showView("viewLogin");
  }

  async function showRegister() {
    showError($("registerError"), "");
    $("registerNotice").hidden = true;
    try {
      await loadSections();
      fillSelect($("registerSection"), { blank: "Choose a section" });
      showView("viewRegister");
    } catch (error) {
      showView("viewRegister");
      showError($("registerError"), friendlyError(error));
    }
  }

  function personLine(person) {
    return [person.rank, person.full_name].filter(Boolean).join(" ");
  }

  function isDirty() {
    return Boolean(document.querySelector("textarea.is-dirty"));
  }

  async function openDiary(traineeId) {
    showError($("diaryError"), "");
    await loadSections();
    var result = await state.client
      .from("profiles")
      .select("id, full_name, rank, section_id, instrument, username, is_staff, sections(name)")
      .eq("id", traineeId)
      .single();
    if (result.error) throw result.error;
    if (!result.data || result.data.is_staff) {
      showView("viewMissing");
      $("missingText").textContent = "That diary is not available.";
      return;
    }

    var now = londonMonth();
    state.diary = {
      trainee: result.data,
      year: now.year,
      month: now.month,
      monthId: null,
      comments: []
    };
    var staffView = state.me.is_staff && state.me.id !== result.data.id;
    $("backRow").hidden = !staffView;
    $("pdfButton").hidden = !state.me.is_staff;
    $("deleteTraineeButton").hidden = !staffView;
    $("passwordPanel").hidden = !staffView;
    $("passwordNote").textContent = staffView
      ? "This replaces the password for " + (result.data.username || "this trainee") + ". The username stays the same."
      : "";
    $("newPassword").value = "";
    $("newPassword2").value = "";
    $("passwordStatus").textContent = "";
    showError($("passwordError"), "");
    $("detailsSummary").textContent = staffView ? "Edit trainee details" : "Your details";
    $("editorNote").hidden = false;
    $("editorNote").textContent = state.me.is_staff
      ? "Any member of staff can write in the four staff boxes. The Trainee box belongs to the trainee. Saving stamps the shared staff name."
      : "You can read every box. Only the Trainee box is yours to write.";
    $("diaryHeading").textContent = staffView ? "Practice diary" : "Your practice diary";
    paintIdentity();
    paintDetailsForm();
    $("month").max = monthValue(now.year, now.month);
    $("month").value = monthValue(now.year, now.month);
    showView("viewDiary");
    await loadMonth();
  }

  function paintIdentity() {
    var trainee = state.diary.trainee;
    var section = (trainee.sections && trainee.sections.name) || sectionName(trainee.section_id) || "No section";
    $("diaryIdentity").textContent = [personLine(trainee), trainee.username, section, trainee.instrument].filter(Boolean).join(" \u00b7 ");
  }

  function paintDetailsForm() {
    var trainee = state.diary.trainee;
    $("detailName").value = trainee.full_name || "";
    $("detailRank").value = trainee.rank || "";
    $("detailInstrument").value = trainee.instrument || "";
    fillSelect($("detailSection"), { selected: trainee.section_id || "" });
    $("detailUsername").textContent = trainee.username
      ? "Username " + trainee.username + " is the login and is not changed here."
      : "";
    $("detailsStatus").textContent = "";
    showError($("detailsError"), "");
  }

  async function loadMonth() {
    var diary = state.diary;
    $("month").value = monthValue(diary.year, diary.month);
    var now = londonMonth();
    $("nextMonth").disabled = diary.year > now.year || (diary.year === now.year && diary.month >= now.month);
    $("prevMonth").disabled = diary.year < 2020 || (diary.year === 2020 && diary.month <= 1);
    announce("Loading " + monthLabel(diary.year, diary.month));
    var ensured = await state.client.rpc("ensure_diary_month", {
      p_trainee: diary.trainee.id,
      p_year: diary.year,
      p_month: diary.month
    });
    if (ensured.error) throw ensured.error;
    diary.monthId = ensured.data;
    var comments = await state.client
      .from("diary_comments")
      .select("id, box_type, body, last_edited_at, last_edited_name, sort_order")
      .eq("diary_month_id", diary.monthId)
      .order("sort_order");
    if (comments.error) throw comments.error;
    diary.comments = comments.data || [];
    renderComments();
    announce(monthLabel(diary.year, diary.month) + " loaded");
  }

  function canEdit(box) {
    if (!state.me || !state.diary) return false;
    if (box.type === "trainee") return !state.me.is_staff && state.me.id === state.diary.trainee.id;
    return state.me.is_staff && box.staff;
  }

  function renderComments() {
    var list = $("commentList");
    list.replaceChildren();
    BOXES.forEach(function (box) {
      var comment = state.diary.comments.find(function (row) { return row.box_type === box.type; });
      var article = document.createElement("article");
      article.className = "comment";
      var head = document.createElement("div");
      head.className = "comment-head";
      var heading = document.createElement("h3");
      heading.textContent = box.label;
      var meta = document.createElement("p");
      meta.className = "meta";
      meta.textContent = editedLine(comment);
      head.append(heading, meta);

      var editable = canEdit(box) && comment;
      var textarea = document.createElement("textarea");
      textarea.value = comment ? comment.body : "";
      textarea.maxLength = 12000;
      textarea.readOnly = !editable;
      textarea.setAttribute("aria-label", box.label);
      if (!editable) textarea.setAttribute("aria-readonly", "true");

      var count = document.createElement("p");
      count.className = "count";
      var updateCount = function () {
        count.textContent = textarea.value.length + " / 12000";
      };
      updateCount();
      textarea.addEventListener("input", function () {
        textarea.classList.toggle("is-dirty", textarea.value !== (comment ? comment.body : ""));
        updateCount();
      });

      article.append(head, textarea, count);
      if (editable) {
        var row = document.createElement("div");
        row.className = "comment-save";
        var button = document.createElement("button");
        button.type = "button";
        button.textContent = "Save";
        var status = document.createElement("p");
        status.className = "note";
        status.setAttribute("role", "status");
        button.addEventListener("click", function () {
          saveComment(comment, textarea, meta, status, button);
        });
        row.append(button, status);
        article.append(row);
      } else {
        var note = document.createElement("p");
        note.className = "readonly-note";
        note.textContent = box.staff
          ? "Only ITT staff can write in this box."
          : "Only the trainee can write in this box.";
        article.append(note);
      }
      list.append(article);
    });
  }

  async function saveComment(comment, textarea, meta, status, button) {
    button.disabled = true;
    status.textContent = "Saving\u2026";
    var result = await state.client
      .from("diary_comments")
      .update({ body: textarea.value })
      .eq("id", comment.id)
      .select("id, body, last_edited_at, last_edited_name, box_type")
      .single();
    button.disabled = false;
    if (result.error) {
      status.textContent = friendlyError(result.error);
      return;
    }
    comment.body = result.data.body;
    comment.last_edited_at = result.data.last_edited_at;
    comment.last_edited_name = result.data.last_edited_name;
    textarea.value = result.data.body;
    textarea.classList.remove("is-dirty");
    meta.textContent = editedLine(comment);
    status.textContent = "Saved";
    announce(comment.box_type + " saved");
  }

  async function changeMonth(next) {
    var now = londonMonth();
    if (next.year < 2020 || (next.year === 2020 && next.month < 1)) return;
    if (next.year > now.year || (next.year === now.year && next.month > now.month)) {
      $("month").value = monthValue(state.diary.year, state.diary.month);
      return;
    }
    if (next.year === state.diary.year && next.month === state.diary.month) return;
    if (isDirty()) {
      var ok = await askConfirm({
        title: "Leave this month?",
        body: "There are unsaved comments on this month. Leave without saving them?",
        confirmLabel: "Leave without saving",
        danger: true
      });
      if (!ok) {
        $("month").value = monthValue(state.diary.year, state.diary.month);
        return;
      }
    }
    state.diary.year = next.year;
    state.diary.month = next.month;
    try {
      await loadMonth();
    } catch (error) {
      showError($("diaryError"), friendlyError(error));
    }
  }

  function askConfirm(options) {
    return new Promise(function (resolve) {
      var dialog = $("confirmDialog");
      var settled = false;
      $("confirmTitle").textContent = options.title;
      $("confirmBody").textContent = options.body;
      $("confirmOk").textContent = options.confirmLabel || "Confirm";
      $("confirmOk").classList.toggle("danger", Boolean(options.danger));
      function finish(value) {
        if (settled) return;
        settled = true;
        dialog.removeEventListener("cancel", onCancel);
        $("confirmOk").removeEventListener("click", onOk);
        $("confirmCancel").removeEventListener("click", onCancel);
        if (dialog.open) dialog.close();
        resolve(value);
      }
      function onOk() { finish(true); }
      function onCancel() { finish(false); }
      $("confirmOk").addEventListener("click", onOk);
      $("confirmCancel").addEventListener("click", onCancel);
      dialog.addEventListener("cancel", onCancel);
      dialog.showModal();
      (options.danger ? $("confirmCancel") : $("confirmOk")).focus();
    });
  }

  async function showStaff() {
    showError($("staffError"), "");
    await loadSections();
    fillSelect($("sectionFilter"), { blank: "All sections", selected: $("sectionFilter").value });
    $("accountName").value = state.me.full_name === "New account" ? "" : state.me.full_name;
    $("accountRank").value = state.me.rank || "";
    $("accountEmail").textContent = "This login is shared. Diaries show this name on staff comments. Set it to ITT Staff.";
    if (state.me.full_name === "New account") $("accountPanel").open = true;
    var result = await state.client
      .from("profiles")
      .select("id, full_name, rank, section_id, instrument, username, sections(name, sort_order)")
      .eq("is_staff", false)
      .order("full_name");
    if (result.error) throw result.error;
    state.trainees = result.data || [];
    renderSectionsAdmin();
    renderTrainees();
    showView("viewStaff");
  }

  function renderTrainees() {
    var query = $("search").value.trim().toLowerCase();
    var sectionId = $("sectionFilter").value;
    var filtered = state.trainees.filter(function (trainee) {
      var nameOk = trainee.full_name.toLowerCase().indexOf(query) !== -1
        || String(trainee.username || "").indexOf(query) !== -1;
      var sectionOk = !sectionId || trainee.section_id === sectionId;
      return nameOk && sectionOk;
    });
    var countLabel = filtered.length === 1 ? "1 trainee" : filtered.length + " trainees";
    $("traineeCount").textContent = countLabel;
    var host = $("traineeResults");
    host.replaceChildren();
    if (!filtered.length) {
      var empty = document.createElement("p");
      empty.className = "note";
      empty.textContent = state.trainees.length
        ? "No trainees match that search."
        : "No trainees have registered yet.";
      host.append(empty);
      return;
    }

    var groups = [];
    if (sectionId) {
      groups.push({ title: "", people: filtered });
    } else {
      var bySection = new Map();
      filtered.forEach(function (trainee) {
        var key = trainee.section_id || "";
        if (!bySection.has(key)) bySection.set(key, []);
        bySection.get(key).push(trainee);
      });
      var ordered = state.sections.slice();
      ordered.push({ id: "", name: "No section", sort_order: 9999 });
      ordered.forEach(function (section) {
        var people = bySection.get(section.id || "") || bySection.get(section.id);
        if (people && people.length) groups.push({ title: section.name, people: people });
      });
    }

    groups.forEach(function (group) {
      if (group.title) {
        var heading = document.createElement("h3");
        heading.className = "group-title";
        heading.textContent = group.title;
        host.append(heading);
      }
      var list = document.createElement("ul");
      list.className = "trainee-list";
      group.people.forEach(function (trainee) {
        var item = document.createElement("li");
        var button = document.createElement("button");
        button.type = "button";
        button.className = "trainee-card";
        var name = document.createElement("span");
        name.className = "trainee-name";
        name.textContent = personLine(trainee);
        var meta = document.createElement("span");
        meta.className = "trainee-meta";
        var section = (trainee.sections && trainee.sections.name) || sectionName(trainee.section_id);
        meta.textContent = [trainee.username, section, trainee.instrument].filter(Boolean).join(" \u00b7 ");
        button.append(name, meta);
        button.addEventListener("click", function () {
          location.hash = "#staff/" + trainee.id;
        });
        item.append(button);
        list.append(item);
      });
      host.append(list);
    });
  }

  function renderSectionsAdmin() {
    var list = $("sectionList");
    list.replaceChildren();
    state.sections.forEach(function (section) {
      var item = document.createElement("li");
      item.className = "section-row";
      var input = document.createElement("input");
      input.type = "text";
      input.value = section.name;
      input.maxLength = 40;
      input.setAttribute("aria-label", "Section name");
      var save = document.createElement("button");
      save.type = "button";
      save.className = "secondary";
      save.textContent = "Rename";
      var remove = document.createElement("button");
      remove.type = "button";
      remove.className = "secondary";
      remove.textContent = "Remove";
      save.addEventListener("click", function () { renameSection(section, input.value, save); });
      remove.addEventListener("click", function () { removeSection(section); });
      item.append(input, save, remove);
      list.append(item);
    });
  }

  async function renameSection(section, name, button) {
    var trimmed = name.trim();
    if (!trimmed) {
      $("sectionStatus").textContent = "A section needs a name.";
      return;
    }
    button.disabled = true;
    var result = await state.client.from("sections").update({ name: trimmed }).eq("id", section.id);
    button.disabled = false;
    if (result.error) {
      $("sectionStatus").textContent = friendlyError(result.error);
      return;
    }
    $("sectionStatus").textContent = "Section saved.";
    await showStaff();
  }

  async function removeSection(section) {
    var ok = await askConfirm({
      title: "Remove " + section.name + "?",
      body: "Trainees in this section must be moved first. This does not delete any diary.",
      confirmLabel: "Remove section",
      danger: true
    });
    if (!ok) return;
    var result = await state.client.from("sections").delete().eq("id", section.id);
    if (result.error) {
      var message = /foreign key|23503/i.test(result.error.message || "") || result.error.code === "23503"
        ? "Move trainees out of this section first."
        : friendlyError(result.error);
      $("sectionStatus").textContent = message;
      return;
    }
    $("sectionStatus").textContent = section.name + " removed.";
    await showStaff();
  }

  async function downloadPdf() {
    if (isDirty()) {
      showError($("diaryError"), "Save the open comments before downloading the PDF.");
      return;
    }
    showError($("diaryError"), "");
    var trainee = state.diary.trainee;
    var section = (trainee.sections && trainee.sections.name) || sectionName(trainee.section_id);
    var byType = {};
    state.diary.comments.forEach(function (comment) { byType[comment.box_type] = comment; });
    try {
      $("pdfButton").disabled = true;
      await window.ITTPdf.downloadDiaryPdf({
        fullName: trainee.full_name,
        rank: trainee.rank,
        section: section,
        instrument: trainee.instrument,
        monthLabel: monthLabel(state.diary.year, state.diary.month),
        boxes: BOXES.map(function (box) {
          var comment = byType[box.type];
          return {
            label: box.label,
            text: comment ? comment.body : "",
            edited: editedLine(comment)
          };
        })
      });
      announce("PDF downloaded");
    } catch (error) {
      showError($("diaryError"), friendlyError(error));
    } finally {
      $("pdfButton").disabled = false;
    }
  }

  async function deleteOpenTrainee() {
    var trainee = state.diary.trainee;
    var ok = await askConfirm({
      title: "Delete " + personLine(trainee) + "?",
      body: "This permanently deletes " + personLine(trainee) + " and every month of their diary. This cannot be undone.",
      confirmLabel: "Delete trainee",
      danger: true
    });
    if (!ok) return;
    var result = await state.client.rpc("delete_trainee", { p_trainee: trainee.id });
    if (result.error) {
      showError($("diaryError"), friendlyError(result.error));
      return;
    }
    announce("Trainee deleted");
    location.hash = "#staff";
  }

  function bind() {
    $("logoutButton").addEventListener("click", async function () {
      if (isDirty()) {
        var ok = await askConfirm({
          title: "Log out?",
          body: "There are unsaved comments. Log out without saving them?",
          confirmLabel: "Log out",
          danger: true
        });
        if (!ok) return;
      }
      await state.client.auth.signOut();
      state.session = null;
      state.me = null;
      state.diary = null;
      location.hash = "#login";
    });

    $("passwordForm").addEventListener("submit", async function (event) {
      event.preventDefault();
      showError($("passwordError"), "");
      var password = $("newPassword").value;
      var again = $("newPassword2").value;
      if (password !== again) {
        showError($("passwordError"), "The passwords do not match.");
        return;
      }
      if (password.length < 8) {
        showError($("passwordError"), "Use a password of at least 8 characters.");
        return;
      }
      var button = $("passwordSubmit");
      button.disabled = true;
      $("passwordStatus").textContent = "Saving\u2026";
      var result = await state.client.rpc("set_trainee_password", {
        p_trainee: state.diary.trainee.id,
        p_password: password
      });
      button.disabled = false;
      $("newPassword").value = "";
      $("newPassword2").value = "";
      if (result.error) {
        $("passwordStatus").textContent = "";
        showError($("passwordError"), friendlyError(result.error));
        return;
      }
      $("passwordStatus").textContent = "Password saved. The trainee signs in with their username and this password.";
    });

    $("loginForm").addEventListener("submit", async function (event) {
      event.preventDefault();
      showError($("loginError"), "");
      var button = $("loginSubmit");
      var staffMode = $("loginForm").dataset.mode === "staff";
      var email = loginEmailFor(normaliseUsername($("loginUsername").value), staffMode);
      if (!email) {
        showError($("loginError"), "Username or password is not recognised.");
        $("loginPassword").value = "";
        return;
      }
      button.disabled = true;
      var result = await state.client.auth.signInWithPassword({
        email: email,
        password: $("loginPassword").value
      });
      button.disabled = false;
      $("loginPassword").value = "";
      if (result.error) {
        showError($("loginError"), "Username or password is not recognised.");
        return;
      }
      state.session = result.data.session;
      state.me = null;
      location.hash = "#home";
    });

    $("registerForm").addEventListener("submit", async function (event) {
      event.preventDefault();
      showError($("registerError"), "");
      $("registerNotice").hidden = true;
      var password = $("registerPassword").value;
      var again = $("registerPassword2").value;
      var username = normaliseUsername($("registerUsername").value);
      var nameProblem = usernameProblem(username);
      if (nameProblem) {
        showError($("registerError"), nameProblem);
        return;
      }
      if (password !== again) {
        showError($("registerError"), "The passwords do not match.");
        return;
      }
      if (password.length < 8) {
        showError($("registerError"), "Use a password of at least 8 characters.");
        return;
      }
      var button = $("registerSubmit");
      button.disabled = true;
      var result = await state.client.auth.signUp({
        email: username + "@trainee.itt-diary.invalid",
        password: password,
        options: {
          data: {
            username: username,
            full_name: $("registerName").value.trim(),
            rank: $("registerRank").value.trim(),
            section_id: $("registerSection").value,
            instrument: $("registerInstrument").value.trim()
          }
        }
      });
      button.disabled = false;
      $("registerPassword").value = "";
      $("registerPassword2").value = "";
      if (result.error) {
        showError($("registerError"), friendlyError(result.error));
        return;
      }
      if (!result.data.session) {
        $("registerNotice").hidden = false;
        $("registerNotice").textContent = "The account was created. Log in with your username. These usernames cannot receive email, so confirmation mail must be turned off.";
        return;
      }
      state.session = result.data.session;
      state.me = null;
      location.hash = "#diary";
    });

    $("detailsForm").addEventListener("submit", async function (event) {
      event.preventDefault();
      showError($("detailsError"), "");
      var trainee = state.diary.trainee;
      var payload = {
        full_name: $("detailName").value.trim(),
        rank: $("detailRank").value.trim(),
        section_id: $("detailSection").value,
        instrument: $("detailInstrument").value.trim()
      };
      var result = await state.client
        .from("profiles")
        .update(payload)
        .eq("id", trainee.id)
        .select("id, full_name, rank, section_id, instrument, username, is_staff, sections(name)")
        .single();
      if (result.error) {
        showError($("detailsError"), friendlyError(result.error));
        return;
      }
      state.diary.trainee = result.data;
      if (state.me.id === result.data.id) state.me = Object.assign({}, state.me, result.data);
      paintIdentity();
      setSessionBar();
      $("detailsStatus").textContent = "Details saved.";
    });

    $("accountForm").addEventListener("submit", async function (event) {
      event.preventDefault();
      var result = await state.client
        .from("profiles")
        .update({
          full_name: $("accountName").value.trim(),
          rank: $("accountRank").value.trim()
        })
        .eq("id", state.me.id)
        .select("id, full_name, rank, section_id, instrument, username, is_staff")
        .single();
      if (result.error) {
        $("accountStatus").textContent = friendlyError(result.error);
        return;
      }
      state.me = result.data;
      setSessionBar();
      $("accountStatus").textContent = "Name saved. New comments use this name.";
    });

    $("addSectionForm").addEventListener("submit", async function (event) {
      event.preventDefault();
      var name = $("newSection").value.trim();
      if (!name) return;
      var sort = state.sections.reduce(function (max, section) {
        return Math.max(max, section.sort_order || 0);
      }, 0) + 1;
      var result = await state.client.from("sections").insert({ name: name, sort_order: sort }).select().single();
      if (result.error) {
        $("sectionStatus").textContent = friendlyError(result.error);
        return;
      }
      $("newSection").value = "";
      $("sectionStatus").textContent = name + " added.";
      await showStaff();
    });

    $("search").addEventListener("input", renderTrainees);
    $("sectionFilter").addEventListener("change", renderTrainees);
    $("prevMonth").addEventListener("click", function () {
      changeMonth(shiftMonth(state.diary.year, state.diary.month, -1));
    });
    $("nextMonth").addEventListener("click", function () {
      changeMonth(shiftMonth(state.diary.year, state.diary.month, 1));
    });
    $("month").addEventListener("change", function () {
      changeMonth(parseMonth($("month").value));
    });
    $("pdfButton").addEventListener("click", downloadPdf);
    $("deleteTraineeButton").addEventListener("click", deleteOpenTrainee);

    window.addEventListener("hashchange", function () { route(); });
    window.addEventListener("beforeunload", function (event) {
      if (!isDirty()) return;
      event.preventDefault();
      event.returnValue = "";
    });
  }

  async function boot() {
    bind();
    var problem = configProblem();
    if (problem) {
      showView("viewSetup");
      return;
    }
    try {
      state.client = window.supabase.createClient(
        window.ITT_CONFIG.supabaseUrl,
        window.ITT_CONFIG.supabaseAnonKey,
        {
          auth: {
            persistSession: true,
            autoRefreshToken: true,
            detectSessionInUrl: true
          }
        }
      );
    } catch (error) {
      showView("viewSetup");
      return;
    }
    state.client.auth.onAuthStateChange(function (event, session) {
      if (event === "SIGNED_OUT") {
        state.session = null;
        state.me = null;
        setSessionBar();
      } else if (session) {
        state.session = session;
      }
    });
    var existing = await state.client.auth.getSession();
    state.session = existing.data.session;
    if (!location.hash) location.hash = state.session ? "#home" : "#";
    await route();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
