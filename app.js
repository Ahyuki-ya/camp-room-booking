'use strict';
// =====================================================================
// 合宿 部屋予約システム / 要件定義書 v2
//
// 依存ゼロ。supabase-js を使わず PostgREST を fetch で直接呼ぶ (§7.2)。
// ユーザー入力の DOM 挿入は textContent のみ。innerHTML は使用しない (§7.4-6)。
// =====================================================================

var C = window.CONFIG || {};
var REST = C.SUPABASE_URL + '/rest/v1/';
var LIMIT_PER_SESSION = 2;
var CANCEL_CUTOFF_MS = 30 * 60 * 1000;   // 開始30分前まで (§FR-03)
var POLL_MS = 30 * 1000;                 // 自動再取得 (§FR-01)

// --- 状態 -----------------------------------------------------------
var rooms = [];          // [{id, name, sort_order}]
var slots = [];          // [{start_at, session_date, ms}]
var reservations = [];   // [{id, room_id, start_at, group_name, ms}]
var sessions = [];       // ['2026-09-02', ...]
var currentSession = null;
var clockOffset = 0;     // サーバ時刻 - 端末時刻 (§FR-06)
var modalOpen = false;
var pollTimer = null;
var booted = false;

// --- 管理モード (§14) -------------------------------------------------
// URL に #admin が付いているときだけ入口が現れる。パスワードは sessionStorage
// に置く（localStorage にすると端末を貸したときに管理権限まで貸すことになる）。
var ADMIN_PW_KEY = 'camp_admin_pw';
var adminMode = false;
var adminPassword = null;

// --- 端末ID (§FR-04) -------------------------------------------------
// 初回アクセス時に UUID を作って localStorage に置き、端末単位の枠数上限に
// 使う。消去・プライベートブラウズ・別ブラウザで簡単に回避できる「柵」で
// あって認証の代替ではない。仕様として承知の上で採用している。
// localStorage が使えない環境では保存を諦め、その場限りのIDで動作を続ける
// （上限は実質無効になるが、エラーで止めるよりはよい）。
var DEVICE_KEY = 'camp_device_id';
var UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function newUuid() {
  var c = window.crypto || window.msCrypto;
  if (c && c.randomUUID) return c.randomUUID();
  var b = new Uint8Array(16);
  if (c && c.getRandomValues) {
    c.getRandomValues(b);
  } else {
    for (var j = 0; j < 16; j++) b[j] = Math.floor(Math.random() * 256);
  }
  b[6] = (b[6] & 0x0f) | 0x40;   // version 4
  b[8] = (b[8] & 0x3f) | 0x80;   // variant
  var h = [];
  for (var i = 0; i < 16; i++) h.push((b[i] + 0x100).toString(16).slice(1));
  return h.slice(0, 4).join('') + '-' + h.slice(4, 6).join('') + '-' +
         h.slice(6, 8).join('') + '-' + h.slice(8, 10).join('') + '-' +
         h.slice(10, 16).join('');
}

var deviceId = (function () {
  var v = null;
  try { v = localStorage.getItem(DEVICE_KEY); } catch (e) { /* 利用不可 */ }
  if (!v || !UUID_RE.test(v)) {
    v = newUuid();
    try { localStorage.setItem(DEVICE_KEY, v); } catch (e) { /* 保存できずとも続行 */ }
  }
  return v;
})();

// --- エラーコード → 表示文言 (§10) ----------------------------------
var MESSAGES = {
  SLOT_TAKEN:         'この枠は他のグループが予約しました',
  DUPLICATE_IN_SLOT:  '同じ時間帯にすでに別の部屋を予約しています',
  LIMIT_EXCEEDED:     '1グループの予約はその晩あたり最大' + LIMIT_PER_SESSION + '枠までです。既存の予約をキャンセルしてください',
  DEVICE_LIMIT_EXCEEDED: 'この端末からの予約はその晩あたり最大' + LIMIT_PER_SESSION + '枠までです。既存の予約をキャンセルしてください',
  PAST_SLOT:          'この時間帯はすでに開始しています',
  NO_SUCH_SLOT:       'この時間帯は予約対象外です',
  NO_SUCH_ROOM:       'その部屋は存在しません',
  TOO_LATE:           '開始30分前を過ぎたためキャンセルできません',
  INVALID_GROUP_NAME: 'グループ名は1〜30文字で入力してください',
  INVALID_ADMIN_PASSWORD: '管理パスワードが違います',
  NO_SUCH_RESERVATION:    'その予約は見つかりません。すでに削除されている可能性があります',
  NO_SUCH_DELETED:        'その削除済み予約は見つかりません',
  RECORD_FROZEN:          '開始時刻を過ぎた記録は固定されています。訂正には理由の記録が必要です',
  REASON_REQUIRED:        '訂正には理由の入力が必要です',
  NETWORK:            '通信に失敗しました。再度お試しください'
};
// 受信したらグリッドを即再取得すべきコード (§10 の「追加動作」)
var REFETCH_ON = {
  SLOT_TAKEN: 1, DUPLICATE_IN_SLOT: 1, PAST_SLOT: 1,
  NO_SUCH_SLOT: 1, NO_SUCH_ROOM: 1, TOO_LATE: 1,
  NO_SUCH_RESERVATION: 1
};

function messageFor(code, context) {
  if (code === 'INVALID_PIN') {
    return context === 'create' ? 'PINは数字4桁で入力してください' : 'PINが違います';
  }
  return MESSAGES[code] || ('エラーが発生しました（' + code + '）');
}

// --- 通信 -----------------------------------------------------------
function syncClock(res) {
  // PostgREST は Access-Control-Expose-Headers に Date を含めるため読める。
  // 読めない環境では端末時計にフォールバックする（オフセット0のまま）。
  var d = res.headers.get('Date');
  if (!d) return;
  var t = Date.parse(d);
  if (!isNaN(t)) clockOffset = t - Date.now();
}

function request(path, options) {
  options = options || {};
  var headers = {
    apikey: C.SUPABASE_ANON_KEY,
    Authorization: 'Bearer ' + C.SUPABASE_ANON_KEY,
    'Content-Type': 'application/json'
  };
  return fetch(REST + path, {
    method: options.method || 'GET',
    headers: headers,
    body: options.body,
    cache: 'no-store'
  }).then(function (res) {
    syncClock(res);
    return res.text().then(function (text) {
      var body = null;
      try { body = text ? JSON.parse(text) : null; } catch (e) { /* 非JSON */ }
      if (!res.ok) {
        // PostgREST のエラーは {code, message, details, hint}。
        // §8.1 の規約により message に機械可読コードが入る。
        var err = new Error('rpc-failed');
        err.code = (body && body.message) ? body.message : 'NETWORK';
        throw err;
      }
      return body;
    });
  }, function () {
    var err = new Error('network');
    err.code = 'NETWORK';
    throw err;
  });
}

function rpc(fn, args) {
  return request('rpc/' + fn, { method: 'POST', body: JSON.stringify(args) });
}

// --- 時刻 (§9.2 表示は Asia/Tokyo 固定) -------------------------------
var JST = 'Asia/Tokyo';
var fmtTime = new Intl.DateTimeFormat('ja-JP', { timeZone: JST, hour: '2-digit', minute: '2-digit', hour12: false });
var fmtDay  = new Intl.DateTimeFormat('en-CA', { timeZone: JST, year: 'numeric', month: '2-digit', day: '2-digit' });
var fmtTab  = new Intl.DateTimeFormat('ja-JP', { timeZone: JST, month: 'numeric', day: 'numeric', weekday: 'short' });

// グリッドの見出し行は sticky でヘッダーの直下に貼り付く。その基準位置は
// ヘッダーの実高さであり、端末の文字サイズ設定やタイトルの折り返しで変わる。
// CSS に固定値を書くと、条件次第で見出し行がヘッダーの裏に潜り込む。
function syncHeaderHeight() {
  var hd = document.querySelector('.hd');
  if (!hd) return;
  document.documentElement.style.setProperty('--hd-h', hd.offsetHeight + 'px');
}

function serverNow() { return Date.now() + clockOffset; }
function hhmm(ms)    { return fmtTime.format(new Date(ms)); }
function jstDay(ms)  { return fmtDay.format(new Date(ms)); }

// session_date ('YYYY-MM-DD') を JST の正午として解釈しラベル化する。
// 正午を使うのは、UTC深夜起点だと環境によって日付がずれる余地を消すため。
function sessionLabel(dateStr) {
  var ms = Date.parse(dateStr + 'T12:00:00+09:00');
  return fmtTab.format(new Date(ms)) + 'の夜';
}

// 行ラベル。session_date と実日付が違えば「翌」を付ける (§9.2)
function slotLabel(slot) {
  var prefix = (jstDay(slot.ms) !== slot.session_date) ? '翌' : '';
  return prefix + hhmm(slot.ms);
}

// --- DOM ヘルパ -----------------------------------------------------
function $(id) { return document.getElementById(id); }
function el(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = text;  // 常に textContent
  return n;
}
function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

var toastTimer = null;
function toast(text, bad) {
  var t = $('toast');
  t.textContent = text;
  t.className = bad ? 'toast bad' : 'toast';
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(function () { t.hidden = true; }, 3000);
}
function setStatus(text, isError) {
  var s = $('status');
  s.textContent = text;
  s.className = isError ? 'status err' : 'status';
}

// --- データ取得 -----------------------------------------------------
function loadStatic() {
  return Promise.all([
    request('rooms?select=id,name,sort_order&order=sort_order'),
    request('slots?select=start_at,session_date&order=start_at')
  ]).then(function (r) {
    rooms = r[0] || [];
    slots = (r[1] || []).map(function (s) {
      return { start_at: s.start_at, session_date: s.session_date, ms: Date.parse(s.start_at) };
    });
    sessions = [];
    slots.forEach(function (s) {
      if (sessions.indexOf(s.session_date) === -1) sessions.push(s.session_date);
    });
    sessions.sort();
  });
}

function loadReservations() {
  return request('reservations?select=id,room_id,start_at,group_name').then(function (rows) {
    reservations = (rows || []).map(function (r) {
      r.ms = Date.parse(r.start_at);
      return r;
    });
  });
}

// --- 描画 -----------------------------------------------------------
function pickInitialSession() {
  // まだ終わっていない最も早いセッションを選ぶ。全て終了なら最後のもの (§9.1)
  var now = serverNow();
  for (var i = 0; i < sessions.length; i++) {
    var last = 0;
    slots.forEach(function (s) { if (s.session_date === sessions[i] && s.ms > last) last = s.ms; });
    if (last + 3600000 > now) return sessions[i];
  }
  return sessions[sessions.length - 1] || null;
}

function renderTabs() {
  var nav = $('tabs');
  clear(nav);
  sessions.forEach(function (d) {
    var b = el('button', d === currentSession ? 'on' : '', sessionLabel(d));
    b.type = 'button';
    b.addEventListener('click', function () { currentSession = d; render(); });
    nav.appendChild(b);
  });
}

function resIndex() {
  var map = {};
  reservations.forEach(function (r) { map[r.room_id + '@' + r.ms] = r; });
  return map;
}

function renderGrid() {
  var wrap = $('grid');
  clear(wrap);
  var mine = slots.filter(function (s) { return s.session_date === currentSession; });
  if (!mine.length || !rooms.length) {
    wrap.appendChild(el('p', 'empty', '予約可能な枠がありません。'));
    return;
  }
  var now = serverNow();
  var byCell = resIndex();

  var table = el('table', 'grid');
  var thead = el('thead');
  var hr = el('tr');
  hr.appendChild(el('th', 'tcol', ''));
  rooms.forEach(function (rm) { hr.appendChild(el('th', '', rm.name)); });
  thead.appendChild(hr);
  table.appendChild(thead);

  var tbody = el('tbody');
  mine.forEach(function (slot) {
    var tr = el('tr');
    tr.appendChild(el('td', 'tcell', slotLabel(slot)));
    rooms.forEach(function (rm) {
      var td = el('td');
      var res = byCell[rm.id + '@' + slot.ms];
      var isPast = slot.ms <= now;
      var isLocked = (slot.ms - CANCEL_CUTOFF_MS) <= now;
      var btn = el('button');
      btn.type = 'button';

      if (res && isPast) {
        btn.className = 'cell past';
        btn.textContent = res.group_name;
        btn.disabled = true;
      } else if (res) {
        btn.className = isLocked ? 'cell locked' : 'cell taken';
        btn.textContent = res.group_name;
        // 管理モードでは PIN を問わず削除できる。キャンセル期限も無視する
        // （期限を過ぎた予約を消せることが管理モードの主目的のため）。
        btn.addEventListener('click', function () {
          if (adminMode) { openAdminDelete(res, rm, slot); }
          else { openDelete(res, rm, slot, isLocked); }
        });
      } else if (isPast) {
        btn.className = 'cell past';
        btn.textContent = '—';
        btn.disabled = true;
      } else {
        btn.className = 'cell free';
        btn.textContent = '空';
        btn.addEventListener('click', function () { openCreate(rm, slot); });
      }
      td.appendChild(btn);
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  wrap.appendChild(table);
}

function render() {
  $('clock').textContent = hhmm(serverNow()) + ' JST';
  renderTabs();
  renderGrid();
  scheduleStateTick();
}

// セルが押せるかどうかは時刻で変わる（開始済み -> 操作不可、開始30分前 ->
// キャンセル不可）。再取得のタイミングでしか描き直さないと、ポーリング間隔の
// あいだ開始済みの枠が押せるまま残る。サーバが弾くので実害はないが、参加者に
// はエラーとして見える。次に状態が変わる瞬間を求めて、そこで描き直す。
var stateTimer = null;

function scheduleStateTick() {
  if (stateTimer) { clearTimeout(stateTimer); stateTimer = null; }
  if (!booted) return;

  var now = serverNow();
  var next = Infinity;
  slots.forEach(function (s) {
    var bounds = [s.ms, s.ms - CANCEL_CUTOFF_MS];
    for (var i = 0; i < bounds.length; i++) {
      if (bounds[i] > now && bounds[i] < next) next = bounds[i];
    }
  });

  // 境界が遠くても60秒ごとには見直す。端末のスリープや時計のずれの保険。
  var wait = Math.min(next - now + 500, 60000);
  if (!(wait >= 500)) wait = 60000;

  stateTimer = setTimeout(function () {
    stateTimer = null;
    // モーダルを開いている間に描き直すと操作中の画面が入れ替わる。
    // 描き直さずに次の見直しだけ予約する。
    if (modalOpen) { scheduleStateTick(); return; }
    render();
  }, wait);
}

// --- 予約モーダル ---------------------------------------------------
var createTarget = null;

function openCreate(room, slot) {
  createTarget = { room: room, slot: slot };
  $('createTarget').textContent = room.name + ' / ' + sessionLabel(slot.session_date) + ' ' + slotLabel(slot);
  $('groupName').value = '';
  $('createPin').value = '';
  $('createError').hidden = true;
  $('createOk').disabled = false;
  $('createModal').hidden = false;
  modalOpen = true;
  $('groupName').focus();
}

function closeCreate() {
  $('createModal').hidden = true;
  modalOpen = false;
  createTarget = null;
}

function submitCreate() {
  if (!createTarget) return;
  var name = $('groupName').value.trim();
  var pin = $('createPin').value.trim();
  var errBox = $('createError');

  // クライアント側の事前チェック。サーバ側の検証は省略されない (§10)
  if (name.length < 1 || name.length > 30) {
    errBox.textContent = messageFor('INVALID_GROUP_NAME');
    errBox.hidden = false; return;
  }
  if (!/^[0-9]{4}$/.test(pin)) {
    errBox.textContent = messageFor('INVALID_PIN', 'create');
    errBox.hidden = false; return;
  }

  var btn = $('createOk');
  btn.disabled = true;                       // 二重送信防止 (§FR-02)
  errBox.hidden = true;

  rpc('create_reservation', {
    p_room_id: createTarget.room.id,
    p_start_at: createTarget.slot.start_at,
    p_group_name: name,
    p_pin: pin,
    p_device_id: deviceId
  }).then(function () {
    closeCreate();
    toast('予約しました');
    return refresh();
  }, function (err) {
    var code = err.code;
    errBox.textContent = messageFor(code, 'create');
    errBox.hidden = false;
    btn.disabled = false;
    if (REFETCH_ON[code]) refresh();
  });
}

// --- キャンセルモーダル ---------------------------------------------
var deleteTarget = null;

function openDelete(res, room, slot, isLocked) {
  deleteTarget = res;
  // 管理用と同じモーダルを使い回すため、文言を毎回戻す
  $('deleteTitle').textContent = '予約のキャンセル';
  $('deleteOk').textContent = 'キャンセルする';
  $('deleteTarget').textContent = room.name + ' / ' + slotLabel(slot) + ' / ' + res.group_name;
  $('deletePin').value = '';
  $('deleteError').hidden = true;
  $('deleteBody').hidden = isLocked;
  $('deleteOk').hidden = isLocked;
  $('deleteOk').disabled = false;
  if (isLocked) {
    $('deleteError').textContent = messageFor('TOO_LATE');
    $('deleteError').hidden = false;
  }
  $('deleteModal').hidden = false;
  modalOpen = true;
  if (!isLocked) $('deletePin').focus();
}

function closeDelete() {
  $('deleteModal').hidden = true;
  modalOpen = false;
  deleteTarget = null;
}

function submitDelete() {
  if (!deleteTarget) return;
  var errBox = $('deleteError');
  var btn = $('deleteOk');
  var call, done;

  if (adminMode) {
    call = rpc('admin_delete_reservation', { p_id: deleteTarget.id, p_password: adminPassword });
    done = '削除しました';
  } else {
    var pin = $('deletePin').value.trim();
    if (!/^[0-9]{4}$/.test(pin)) {
      errBox.textContent = messageFor('INVALID_PIN', 'delete');
      errBox.hidden = false; return;
    }
    call = rpc('cancel_reservation', { p_id: deleteTarget.id, p_pin: pin });
    done = 'キャンセルしました';
  }

  btn.disabled = true;
  errBox.hidden = true;

  call.then(function () {
    closeDelete();
    toast(done);
    return refresh();
  }, function (err) {
    var code = err.code;
    errBox.textContent = messageFor(code, 'delete');
    errBox.hidden = false;
    btn.disabled = false;
    if (REFETCH_ON[code]) refresh();
  });
}

// --- 再取得とポーリング (§FR-07) --------------------------------------
function refresh() {
  return loadReservations().then(function () {
    render();
    setStatus('更新 ' + hhmm(serverNow()));
  }, function () {
    setStatus(MESSAGES.NETWORK, true);
    toast(MESSAGES.NETWORK, true);
  });
}

function schedulePoll() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(tick, POLL_MS);
}

function tick() {
  // モーダル表示中とタブ非表示中は取得しない
  if (modalOpen || document.hidden) { schedulePoll(); return; }
  refresh().then(schedulePoll, schedulePoll);
}

// --- 起動 -----------------------------------------------------------
function boot() {
  $('campName').textContent = C.CAMP_NAME || '合宿 部屋予約';
  document.title = C.CAMP_NAME || '合宿 部屋予約';

  if (!C.SUPABASE_URL || C.SUPABASE_URL.indexOf('YOUR-PROJECT-REF') !== -1) {
    $('grid').appendChild(el('p', 'empty',
      'config.js の SUPABASE_URL と SUPABASE_ANON_KEY を設定してください。' +
      'あわせて index.html の Content-Security-Policy の connect-src も同じホストに書き換えてください。'));
    return;
  }

  syncHeaderHeight();
  setStatus('読み込み中…');
  loadStatic().then(function () {
    currentSession = pickInitialSession();
    booted = true;
    return refresh();
  }).then(function () {
    initAdmin();
    schedulePoll();
  }, function () {
    setStatus(MESSAGES.NETWORK, true);
    $('grid').appendChild(el('p', 'empty', MESSAGES.NETWORK));
  });

  // 時計の表示だけは毎分更新する
  setInterval(function () {
    if (booted) $('clock').textContent = hhmm(serverNow()) + ' JST';
  }, 60000);

  // 画面回転や文字サイズ変更でヘッダーの高さが変わる。
  // ResizeObserver があれば追随し、無ければ resize でしのぐ。
  if (window.ResizeObserver) {
    new ResizeObserver(syncHeaderHeight).observe(document.querySelector('.hd'));
  } else {
    window.addEventListener('resize', syncHeaderHeight);
    window.addEventListener('orientationchange', syncHeaderHeight);
  }
}


// --- 管理モード (§14) -------------------------------------------------

function roomById(id) {
  for (var i = 0; i < rooms.length; i++) { if (rooms[i].id === id) return rooms[i]; }
  return null;
}

function applyAdminUi() {
  $('adminBar').hidden = !adminMode;
  document.body.classList.toggle('admin', adminMode);
}

// パスワードを検証し、通れば管理モードに入る。
// 失敗時は保持していたパスワードも捨てる（変更されている可能性があるため）。
function enterAdmin(pw, onFail) {
  return rpc('admin_verify', { p_password: pw }).then(function () {
    adminMode = true;
    adminPassword = pw;
    try { sessionStorage.setItem(ADMIN_PW_KEY, pw); } catch (e) { /* 利用不可 */ }
    applyAdminUi();
    render();
    return true;
  }, function (err) {
    adminMode = false;
    adminPassword = null;
    try { sessionStorage.removeItem(ADMIN_PW_KEY); } catch (e) { /* 利用不可 */ }
    applyAdminUi();
    if (onFail) onFail(err);
    return false;
  });
}

function exitAdmin() {
  adminMode = false;
  adminPassword = null;
  try { sessionStorage.removeItem(ADMIN_PW_KEY); } catch (e) { /* 利用不可 */ }
  applyAdminUi();
  if (location.hash === '#admin') {
    history.replaceState(null, '', location.pathname + location.search);
  }
  render();
  toast('管理モードを終了しました');
}

function openAdminAuth() {
  $('adminPw').value = '';
  $('adminAuthError').hidden = true;
  $('adminAuthOk').disabled = false;
  $('adminAuthModal').hidden = false;
  modalOpen = true;
  $('adminPw').focus();
}

function closeAdminAuth() {
  $('adminAuthModal').hidden = true;
  modalOpen = false;
}

function submitAdminAuth() {
  var pw = $('adminPw').value.trim();
  var errBox = $('adminAuthError');
  if (!pw) {
    errBox.textContent = messageFor('INVALID_ADMIN_PASSWORD');
    errBox.hidden = false; return;
  }
  var btn = $('adminAuthOk');
  btn.disabled = true;
  errBox.hidden = true;
  enterAdmin(pw, function (err) {
    errBox.textContent = messageFor(err.code);
    errBox.hidden = false;
    btn.disabled = false;
  }).then(function (ok) {
    if (ok) { closeAdminAuth(); toast('管理モードに入りました'); }
  });
}

// 管理モードでの削除。PIN を問わず、キャンセル期限も無視する。
function openAdminDelete(res, room, slot) {
  deleteTarget = res;
  $('deleteTitle').textContent = '予約の削除（管理）';
  $('deleteOk').textContent = '削除する';
  $('deleteTarget').textContent = room.name + ' / ' + slotLabel(slot) + ' / ' + res.group_name;
  $('deleteBody').hidden = true;
  $('deleteOk').hidden = false;
  $('deleteOk').disabled = false;
  $('deleteError').hidden = true;
  $('deleteModal').hidden = false;
  modalOpen = true;
}

function openRestore() {
  var list = $('restoreList');
  clear(list);
  $('restoreError').hidden = true;
  list.appendChild(el('p', 'note', '読み込み中…'));
  $('restoreModal').hidden = false;
  modalOpen = true;

  rpc('admin_list_deleted', { p_password: adminPassword }).then(function (rows) {
    clear(list);
    if (!rows || !rows.length) {
      list.appendChild(el('p', 'note', '削除した予約はありません。'));
      return;
    }
    rows.forEach(function (r) {
      var rm = roomById(r.room_id);
      var row = el('div', 'restore-row');
      var info = el('div', 'restore-info');
      info.appendChild(el('div', 'restore-name', r.group_name));
      info.appendChild(el('div', 'restore-meta',
        (rm ? rm.name : '部屋' + r.room_id) + ' / ' +
        sessionLabel(r.session_date) + ' ' + hhmm(Date.parse(r.start_at))));
      row.appendChild(info);
      var b = el('button', 'btn-icon', '復元');
      b.type = 'button';
      b.addEventListener('click', function () { doRestore(r.id, b); });
      row.appendChild(b);
      list.appendChild(row);
    });
  }, function (err) {
    clear(list);
    $('restoreError').textContent = messageFor(err.code);
    $('restoreError').hidden = false;
  });
}

// 復元は枠が空いている場合のみ成功する。削除してから誰かが取った場合は
// SLOT_TAKEN になる（§14.3）。その予約を先に消せば復元できる。
function doRestore(id, btn) {
  btn.disabled = true;
  $('restoreError').hidden = true;
  rpc('admin_restore_reservation', { p_id: id, p_password: adminPassword }).then(function () {
    toast('復元しました');
    refresh();
    openRestore();
  }, function (err) {
    $('restoreError').textContent = messageFor(err.code);
    $('restoreError').hidden = false;
    btn.disabled = false;
    if (REFETCH_ON[err.code]) refresh();
  });
}

function closeRestore() {
  $('restoreModal').hidden = true;
  modalOpen = false;
}

// #admin が付いているときだけ入口を開く。
function initAdmin() {
  if (location.hash !== '#admin' || adminMode) return;
  var saved = null;
  try { saved = sessionStorage.getItem(ADMIN_PW_KEY); } catch (e) { /* 利用不可 */ }
  if (saved) { enterAdmin(saved); return; }
  openAdminAuth();
}

$('reloadBtn').addEventListener('click', function () {
  var b = $('reloadBtn');
  b.disabled = true;
  refresh().then(function () { b.disabled = false; }, function () { b.disabled = false; });
});
$('createOk').addEventListener('click', submitCreate);
$('createCancel').addEventListener('click', closeCreate);
$('deleteOk').addEventListener('click', submitDelete);
$('deleteCancel').addEventListener('click', closeDelete);
$('createPin').addEventListener('keydown', function (e) { if (e.key === 'Enter') submitCreate(); });
$('deletePin').addEventListener('keydown', function (e) { if (e.key === 'Enter') submitDelete(); });
$('adminAuthOk').addEventListener('click', submitAdminAuth);
$('adminAuthCancel').addEventListener('click', closeAdminAuth);
$('adminPw').addEventListener('keydown', function (e) { if (e.key === 'Enter') submitAdminAuth(); });
$('adminExit').addEventListener('click', exitAdmin);
$('restoreBtn').addEventListener('click', openRestore);
$('restoreClose').addEventListener('click', closeRestore);
window.addEventListener('hashchange', initAdmin);

document.addEventListener('keydown', function (e) {
  if (e.key !== 'Escape') return;
  if (!$('createModal').hidden)    closeCreate();
  if (!$('deleteModal').hidden)    closeDelete();
  if (!$('adminAuthModal').hidden) closeAdminAuth();
  if (!$('restoreModal').hidden)   closeRestore();
});
document.addEventListener('visibilitychange', function () {
  // 再表示時に即座に1回取得する (§FR-07)
  if (!document.hidden && booted && !modalOpen) { refresh(); schedulePoll(); }
});

boot();
