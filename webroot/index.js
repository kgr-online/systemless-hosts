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

function exec(command) {
  return new Promise((resolve) => {
    const cb = `__hosts_cb_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
    window[cb] = (errno, stdout, stderr) => {
      delete window[cb];
      resolve({ errno, stdout: (stdout || "").trim(), stderr: (stderr || "").trim() });
    };
    try {
      if (window.ksu && typeof window.ksu.exec === "function") {
        window.ksu.exec(command, "{}", cb);
      } else {
        resolve({ errno: -1, stdout: "", stderr: "no webui bridge found" });
      }
    } catch (e) {
      resolve({ errno: -1, stdout: "", stderr: String(e) });
    }
  });
}

function sh(...args) {
  const quoted = args.map((a) => `'${String(a).replace(/'/g, "'\\''")}'`).join(" ");
  return exec(`sh ${CTL} ${quoted}`);
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
document.getElementById("searchInput").addEventListener("input", (e) => onSearch(e.target.value));
document.getElementById("refreshBtn").addEventListener("click", () => { refreshStatus(); refreshCount(); loadList(true); });
document.getElementById("loadMoreBtn").addEventListener("click", () => loadList(false));

refreshStatus();
refreshCount();
loadList(true);
