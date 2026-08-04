// Bot-detection probe: the checks CreepJS / fingerprint.js / sannysoft actually run.
// Prints one FAIL line per tell. Empty FAIL output = clean surface.
window.addEventListener('load', function () {
  const out = [];
  const ok = (name, cond, got) => out.push((cond ? 'PASS ' : 'FAIL ') + name + ' = ' + got);

  // --- the loud ones -------------------------------------------------
  ok('navigator.webdriver', navigator.webdriver === false, navigator.webdriver);
  ok('window.chrome present', typeof window.chrome === 'object', typeof window.chrome);
  ok('chrome.runtime present', !!(window.chrome && window.chrome.runtime), !!(window.chrome && window.chrome.runtime));
  ok('no Chrome ctor leak', typeof window.Chrome === 'undefined', typeof window.Chrome);
  ok('no ChromeRuntime leak', typeof window.ChromeRuntime === 'undefined', typeof window.ChromeRuntime);
  ok('no ModelContext leak', typeof window.ModelContext === 'undefined', typeof window.ModelContext);
  ok('no CrossOriginWindow leak', typeof window.CrossOriginWindow === 'undefined', typeof window.CrossOriginWindow);
  ok('no Console ctor leak', typeof window.Console === 'undefined', typeof window.Console);

  // --- chrome.csi / loadTimes must be non-zero and ordered ------------
  try {
    const csi = window.chrome.csi();
    ok('chrome.csi().startE nonzero', csi.startE > 0, csi.startE);
    ok('chrome.csi().pageT nonzero', csi.pageT > 0, csi.pageT);
    const lt = window.chrome.loadTimes();
    ok('loadTimes ordered', lt.requestTime <= lt.startLoadTime && lt.startLoadTime <= lt.finishLoadTime,
       lt.requestTime + '/' + lt.startLoadTime + '/' + lt.finishLoadTime);
  } catch (e) { out.push('FAIL chrome.csi/loadTimes threw = ' + e.message); }

  // --- screen geometry chain -----------------------------------------
  ok('screen.height > availHeight', screen.height > screen.availHeight, screen.height + '>' + screen.availHeight);
  ok('availHeight >= outerHeight', screen.availHeight >= outerHeight, screen.availHeight + '>=' + outerHeight);
  ok('outerHeight > innerHeight', outerHeight > innerHeight, outerHeight + '>' + innerHeight);
  ok('availTop defined', typeof screen.availTop === 'number', screen.availTop);
  ok('availLeft defined', typeof screen.availLeft === 'number', screen.availLeft);

  // --- UA-CH coherence ------------------------------------------------
  ok('userAgentData present', !!navigator.userAgentData, !!navigator.userAgentData);
  if (navigator.userAgentData) {
    const brands = navigator.userAgentData.brands.map(b => b.brand).join('|');
    ok('brands has Chrome', /Chrome|Chromium/.test(brands), brands);
    ok('UA matches platform', navigator.userAgent.includes('Chrome'), navigator.userAgent.slice(0, 60));
  }
  ok('languages nonempty', navigator.languages.length > 0, navigator.languages.join(','));
  ok('languages frozen', Object.isFrozen(navigator.languages), Object.isFrozen(navigator.languages));
  ok('hardwareConcurrency sane', navigator.hardwareConcurrency >= 2, navigator.hardwareConcurrency);
  ok('deviceMemory present', typeof navigator.deviceMemory === 'number', navigator.deviceMemory);
  ok('pdfViewerEnabled true', navigator.pdfViewerEnabled === true, navigator.pdfViewerEnabled);
  ok('plugins nonempty', navigator.plugins.length > 0, navigator.plugins.length);
  ok('mimeTypes nonempty', navigator.mimeTypes.length > 0, navigator.mimeTypes.length);

  // --- APIs whose absence is a tell ------------------------------------
  ok('RTCPeerConnection', typeof window.RTCPeerConnection === 'function', typeof window.RTCPeerConnection);
  ok('mediaDevices', !!navigator.mediaDevices, !!navigator.mediaDevices);
  ok('getBattery', typeof navigator.getBattery === 'function', typeof navigator.getBattery);
  ok('connection', !!navigator.connection, !!navigator.connection);
  ok('getGamepads', typeof navigator.getGamepads === 'function', typeof navigator.getGamepads);
  ok('WebGL2RenderingContext', typeof window.WebGL2RenderingContext === 'function', typeof window.WebGL2RenderingContext);
  ok('Notification', typeof window.Notification !== 'undefined', typeof window.Notification);
  ok('Intl works', new Intl.NumberFormat('de-DE').format(1234.5) === '1.234,5', new Intl.NumberFormat('de-DE').format(1234.5));
  ok('Intl timezone', !!Intl.DateTimeFormat().resolvedOptions().timeZone, Intl.DateTimeFormat().resolvedOptions().timeZone);

  // --- permissions coherence (classic headless tell) --------------------
  navigator.permissions.query({ name: 'notifications' }).then(function (p) {
    out.push((p.state !== 'denied' || Notification.permission !== 'default' ? 'PASS ' : 'FAIL ') +
      'permissions/Notification coherent = ' + p.state + '/' + Notification.permission);
    finish();
  }).catch(function (e) { out.push('FAIL permissions.query threw = ' + e.message); finish(); });

  // --- fingerprint surfaces must not be blank ---------------------------
  function finish() {
    try {
      const c = document.createElement('canvas');
      c.width = 64; c.height = 32;
      const g = c.getContext('2d');
      g.fillStyle = '#f60'; g.fillRect(0, 0, 40, 20);
      g.fillStyle = '#069'; g.fillText('lp,1234', 2, 15);
      const url = c.toDataURL();
      ok('canvas 2D nonblank', url.length > 200, url.length + ' bytes');

      const gc = document.createElement('canvas');
      const gl = gc.getContext('webgl');
      if (gl) {
        const dbg = gl.getExtension('WEBGL_debug_renderer_info');
        const r = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : '';
        ok('webgl renderer string', !!r && !/swiftshader|llvmpipe|mesa/i.test(r), r);
        const px = new Uint8Array(4 * 16);
        gl.readPixels(0, 0, 4, 4, gl.RGBA, gl.UNSIGNED_BYTE, px);
        const uniq = new Set(px).size;
        ok('webgl readPixels not blank', uniq > 1, 'distinct bytes=' + uniq);
      } else { out.push('FAIL webgl context = null'); }
    } catch (e) { out.push('FAIL fingerprint surfaces threw = ' + e.message); }

    const fails = out.filter(l => l.startsWith('FAIL'));
    console.log('=== PROBE ' + (out.length - fails.length) + '/' + out.length + ' pass ===');
    out.forEach(l => console.log(l));
  }
});
