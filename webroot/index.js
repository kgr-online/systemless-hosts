// Systemless Hosts WebUI
// Talks to hosts_ctl.sh (running as root) via the KernelSU/APatch WebUI
// JS bridge. That bridge is the standard `window.ksu` exec API shared by
// KernelSU, APatch, KsuWebUIStandalone, WebUI-X and MMRL.

const MODDIR = "/data/adb/modules/systemless-hosts";
const CTL = `${MODDIR}/hosts_ctl.sh`;
const PAGE_SIZE = 100;

let offset = 0;
let currentQuery = "";
let busy = false;

const EXEC_TIMEOUT_MS = 8000;

// The KernelSU/APatch WebUI bridge only reliably handles one in-flight
// exec() call at a time - firing several concurrently causes later calls'
// callbacks to silently never fire. Everything funnels through this single
// queue so calls always run one after another, never overlapping.
let execChain = Promise.resolve();

let debugEntries = [];

function logDebug(command, result) {
  debugEntries.unshift({ command, ...result, time: new Date().toLocaleTimeString() });
  debugEntries = debugEntries.slice(0, 20);
  const el = document.getElementById("debugLog");
  if (el) {
    el.textContent = debugEntries
      .map((e) => `[${e.time}] $ ${e.command}\n  errno=${e.errno}\n  stdout="${e.stdout}"\n  stderr="${e.stderr}"`)
      .join("\n\n");
  }
}

function execRaw(command) {
  return new Promise((resolve) => {
    const cb = `__hosts_cb_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      delete window[cb];
      logDebug(command, result);
      resolve(result);
    };
    window[cb] = (errno, stdout, stderr) => {
      finish({ errno, stdout: (stdout || "").trim(), stderr: (stderr || "").trim() });
    };
    try {
      if (window.ksu && typeof window.ksu.exec === "function") {
        window.ksu.exec(command, "{}", cb);
      } else {
        finish({ errno: -1, stdout: "", stderr: "No WebUI bridge found (window.ksu is missing)." });
        return;
      }
    } catch (e) {
      finish({ errno: -1, stdout: "", stderr: String(e) });
      return;
    }
    setTimeout(() => {
      finish({ errno: -1, stdout: "", stderr: `Timed out waiting for a response (>${EXEC_TIMEOUT_MS / 1000}s).` });
    }, EXEC_TIMEOUT_MS);
  });
}

function exec(command) {
  const run = () => execRaw(command).then((result) => {
    if (result.errno !== 0 && result.stderr) showError(result.stderr);
    else clearError();
    return result;
  });
  execChain = execChain.then(run, run);
  return execChain;
}

function sh(...args) {
  const quoted = args.map((a) => `'${String(a).replace(/'/g, "'\\''")}'`).join(" ");
  return exec(`sh ${CTL} ${quoted}`);
}

function showError(msg) {
  const el = document.getElementById("errorBanner");
  el.textContent = msg;
  el.classList.add("show");
}

function clearError() {
  document.getElementById("errorBanner").classList.remove("show");
}

function toast(msg) {
  const el = document.getElementById("toast");
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.remove("show"), 1800);
  if (window.ksu && typeof window.ksu.toast === "function") {
    try { window.ksu.toast(msg); } catch (e) {}
  }
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function parseDomain(line) {
  const parts = line.trim().split(/\s+/);
  return parts.length >= 2 ? parts[1] : line.trim();
}

async function refreshStatus() {
  const { stdout } = await sh("status");
  const enabled = stdout !== "disabled";
  const toggle = document.getElementById("toggle");
  toggle.checked = enabled;
  toggle.disabled = false;
  document.getElementById("statusText").textContent = enabled ? "Filtering active" : "Filtering paused";
  document.getElementById("statusSub").textContent = enabled
    ? "Ads and trackers are being blocked"
    : "Blocking is paused - hosts file is passthrough";
}

async function refreshCount() {
  const { stdout } = await sh("count");
  document.getElementById("countBadge").textContent = stdout ? `${Number(stdout).toLocaleString()} entries` : "";
}

function renderList(lines, append) {
  const container = document.getElementById("listContainer");
  if (!append) container.innerHTML = "";
  if (lines.length === 0 && !append) {
    container.innerHTML = '<div class="empty">No matching entries</div>';
    document.getElementById("loadMoreBtn").style.display = "none";
    return;
  }
  const frag = document.createDocumentFragment();
  lines.forEach((line) => {
    const domain = parseDomain(line);
    if (!domain) return;
    const row = document.createElement("div");
    row.className = "list-item";
    row.innerHTML = `<span>${escapeHtml(domain)}</span>
      <button class="btn-danger" data-domain="${escapeHtml(domain)}"><i class="ti ti-x" aria-hidden="true"></i></button>`;
    row.querySelector("button").addEventListener("click", () => removeDomain(domain));
    frag.appendChild(row);
  });
  container.appendChild(frag);
  document.getElementById("loadMoreBtn").style.display = lines.length < PAGE_SIZE ? "none" : "block";
}

async function loadList(reset) {
  if (busy) return;
  busy = true;
  if (reset) offset = 0;
  const { stdout } = currentQuery
    ? await sh("search", currentQuery, PAGE_SIZE)
    : await sh("list", offset, PAGE_SIZE);
  const lines = stdout ? stdout.split("\n").filter(Boolean) : [];
  renderList(lines, !reset && offset > 0);
  offset += lines.length;
  busy = false;
}

async function toggleFilter(enable) {
  document.getElementById("toggle").disabled = true;
  const { errno } = await sh(enable ? "enable" : "disable");
  await refreshStatus();
  toast(errno === 0 ? (enable ? "Filtering resumed" : "Filtering paused") : "Failed to change state");
}

async function addDomain() {
  const input = document.getElementById("addInput");
  const domain = input.value.trim().toLowerCase();
  if (!domain || !/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/.test(domain)) {
    toast("Enter a valid domain");
    return;
  }
  const { stdout, errno } = await sh("add", domain);
  if (errno === 0 && stdout === "ok") {
    toast(`Added ${domain}`);
    input.value = "";
    await refreshCount();
    if (!currentQuery) await loadList(true);
  } else if (stdout === "exists") {
    toast("Already in the blacklist");
  } else {
    toast("Failed to add");
  }
}

async function removeDomain(domain) {
  const { errno } = await sh("remove", domain);
  if (errno === 0) {
    toast(`Removed ${domain}`);
    await refreshCount();
    await loadList(true);
  } else {
    toast("Failed to remove");
  }
}

function debounce(fn, ms) {
  let t;
  return (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
}

const onSearch = debounce((value) => {
  currentQuery = value.trim();
  loadList(true);
}, 350);

document.getElementById("toggle").addEventListener("change", (e) => toggleFilter(e.target.checked));
document.getElementById("addBtn").addEventListener("click", addDomain);
document.getElementById("addInput").addEventListener("keydown", (e) => { if (e.key === "Enter") addDomain(); });
function runSearch() {
  currentQuery = document.getElementById("searchInput").value.trim();
  loadList(true);
}

document.getElementById("searchInput").addEventListener("input", (e) => onSearch(e.target.value));
document.getElementById("searchBtn").addEventListener("click", runSearch);
document.getElementById("searchInput").addEventListener("keydown", (e) => { if (e.key === "Enter") runSearch(); });
document.getElementById("refreshBtn").addEventListener("click", () => { refreshStatus(); refreshCount(); loadList(true); });
document.getElementById("loadMoreBtn").addEventListener("click", () => loadList(false));
document.getElementById("toggleDebugBtn").addEventListener("click", () => {
  const el = document.getElementById("debugLog");
  const btn = document.getElementById("toggleDebugBtn");
  const show = el.style.display === "none";
  el.style.display = show ? "block" : "none";
  btn.textContent = show ? "Hide" : "Show";
});

function renderSources(lines) {
  const container = document.getElementById("sourcesList");
  if (lines.length === 0) {
    container.innerHTML = '<div class="empty">No sources added - only the bundled default list is active</div>';
    return;
  }
  container.innerHTML = "";
  const frag = document.createDocumentFragment();
  lines.forEach((line) => {
    const m = line.match(/^\s*(\d+)\s+(.*)$/);
    if (!m) return;
    const [, n, url] = m;
    const row = document.createElement("div");
    row.className = "list-item";
    row.innerHTML = `<span style="word-break: break-all;">${escapeHtml(url)}</span>
      <button class="btn-danger" data-n="${n}">Remove</button>`;
    row.querySelector("button").addEventListener("click", () => removeSource(n));
    frag.appendChild(row);
  });
  container.appendChild(frag);
}

async function loadSources() {
  const { stdout } = await sh("src_list");
  const lines = stdout ? stdout.split("\n").filter(Boolean) : [];
  renderSources(lines);
}

async function addSource() {
  const input = document.getElementById("sourceInput");
  const url = input.value.trim();
  if (!/^https?:\/\/.+/i.test(url)) {
    toast("Enter a valid http(s) URL");
    return;
  }
  const { stdout, errno } = await sh("src_add", url);
  if (errno === 0 && stdout === "ok") {
    toast("Source added - tap Update now to fetch it");
    input.value = "";
    await loadSources();
  } else {
    toast("Failed to add source");
  }
}

async function removeSource(n) {
  const { errno } = await sh("src_remove", n);
  if (errno === 0) {
    toast("Source removed");
    await loadSources();
  } else {
    toast("Failed to remove source");
  }
}

async function pollUpdateStatus() {
  const { stdout } = await sh("update_status");
  const statusEl = document.getElementById("updateStatus");
  if (stdout.startsWith("running")) {
    statusEl.textContent = "Fetching sources...";
    setTimeout(pollUpdateStatus, 3000);
  } else if (stdout.startsWith("done")) {
    statusEl.textContent = "Up to date";
    document.getElementById("updateBtn").disabled = false;
    toast("Blacklist updated");
    await refreshCount();
    await loadList(true);
  } else if (stdout.startsWith("error")) {
    statusEl.textContent = "Last update had errors - see Debug log";
    document.getElementById("updateBtn").disabled = false;
    await refreshCount();
    await loadList(true);
  } else {
    statusEl.textContent = "";
    document.getElementById("updateBtn").disabled = false;
  }
}

async function startUpdate() {
  document.getElementById("updateBtn").disabled = true;
  document.getElementById("updateStatus").textContent = "Starting...";
  const { errno } = await sh("update");
  if (errno !== 0) {
    toast("Failed to start update");
    document.getElementById("updateBtn").disabled = false;
    return;
  }
  pollUpdateStatus();
}

document.getElementById("addSourceBtn").addEventListener("click", addSource);
document.getElementById("sourceInput").addEventListener("keydown", (e) => { if (e.key === "Enter") addSource(); });
document.getElementById("updateBtn").addEventListener("click", startUpdate);

refreshStatus();
refreshCount();
loadList(true);
loadSources();
