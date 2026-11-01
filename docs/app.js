/* sitecopy — tarayıcıda çalışan site kopyalayıcı
 *
 * Sayfalar ve dosyalar doğrudan tarayıcıdan indirilir, hiçbir sunucuya yüklenmez.
 * Site kendi kaynağına CORS izni vermediği için okuma işi iki genel köprüden geçer:
 *   · metin (html/css/js)  → r.jina.ai
 *   · resim/font (ikili)   → wsrv.nl
 * Sonuç tek bir ZIP olarak bilgisayara iner.
 */
(() => {
  'use strict';

  const JINA = 'https://r.jina.ai/';
  const WSRV = 'https://wsrv.nl/?url=';
  const ALLORIGINS = 'https://api.allorigins.win/raw?url=';

  const VARLIK_LIMIT = 400;
  const DOSYA_LIMIT = 30 * 1024 * 1024;

  const METIN_UZANTI = new Set(['css', 'js', 'mjs', 'json', 'svg', 'xml', 'txt', 'webmanifest', 'map', 'csv']);
  const IKILI_UZANTI = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'ico', 'tif', 'tiff']);
  const ATLA_UZANTI = new Set(['mp4', 'webm', 'mov', 'avi', 'mkv', 'mp3', 'wav', 'ogg', 'flac',
                               'pdf', 'zip', 'rar', '7z', 'gz', 'tar', 'exe', 'dmg', 'iso',
                               'woff', 'woff2', 'ttf', 'otf', 'eot']);

  const TIP_UZANTI = {
    'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp',
    'image/avif': 'avif', 'image/svg+xml': 'svg', 'image/bmp': 'bmp',
    'image/x-icon': 'ico', 'image/vnd.microsoft.icon': 'ico',
    'font/woff2': 'woff2', 'font/woff': 'woff', 'font/ttf': 'ttf', 'font/otf': 'otf',
    'application/font-woff': 'woff', 'application/x-font-ttf': 'ttf',
    'text/css': 'css', 'text/html': 'html', 'text/plain': 'txt',
    'application/javascript': 'js', 'text/javascript': 'js', 'application/json': 'json',
  };

  const $ = (id) => document.getElementById(id);
  const el = {
    form: $('form'), url: $('url'), sayfa: $('sayfa'), dugme: $('dugme'), js: $('js'),
    durumKarti: $('durumKarti'), rozet: $('rozet'), rozetMetin: $('rozetMetin'),
    kisaBilgi: $('kisaBilgi'), ilerleme: $('ilerleme'), cubuk: $('cubuk'), konsol: $('konsol'),
    basari: $('basari'), basariBilgi: $('basariBilgi'), basariAdres: $('basariAdres'),
    btnIndir: $('btnIndir'), tost: $('tost'), temaBtn: $('temaBtn'),
  };

  const enc = new TextEncoder();
  let calisiyor = false;

  /* ------------------------------------------------------------ yardımcı */

  function tost(mesaj) {
    el.tost.textContent = mesaj;
    el.tost.classList.add('gor');
    clearTimeout(tost._z);
    tost._z = setTimeout(() => el.tost.classList.remove('gor'), 3600);
  }

  function yaz(satir, tur = '') {
    const d = document.createElement('div');
    if (tur) d.className = tur;
    d.textContent = satir;
    el.konsol.appendChild(d);
    while (el.konsol.children.length > 400) el.konsol.removeChild(el.konsol.firstChild);
    el.konsol.scrollTop = el.konsol.scrollHeight;
  }

  function rozet(durum, metin) {
    el.rozet.className = 'rozet ' + durum;
    el.rozetMetin.textContent = metin;
    el.ilerleme.style.display = durum === 'calisiyor' ? 'block' : 'none';
  }

  const bekle = (ms) => new Promise((r) => setTimeout(r, ms));

  function zaman(ms) {
    const c = new AbortController();
    setTimeout(() => c.abort(), ms);
    return c.signal;
  }

  const anahtar = (u) => u.origin + (u.pathname.replace(/\/+$/, '') || '/');

  const uzanti = (u) => {
    const m = /\.([a-z0-9]+)$/i.exec(u.pathname);
    return m ? m[1].toLowerCase() : '';
  };

  const tipUzanti = (tip) => TIP_UZANTI[String(tip || '').split(';')[0].trim().toLowerCase()] || '';

  function kisaHash(metin) {
    let h = 2166136261;
    for (let i = 0; i < metin.length; i++) {
      h ^= metin.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(36).padStart(6, '0').slice(0, 6);
  }

  function goreliYol(hedef, kaynakYol) {
    const kd = kaynakYol.includes('/') ? kaynakYol.slice(0, kaynakYol.lastIndexOf('/') + 1) : '';
    const kaynakParca = kd ? kd.split('/').filter(Boolean) : [];
    const hedefParca = hedef.split('/');
    let i = 0;
    while (i < hedefParca.length - 1 && i < kaynakParca.length && hedefParca[i] === kaynakParca[i]) i++;
    return '../'.repeat(kaynakParca.length - i) + hedefParca.slice(i).join('/');
  }

  function sayfaYolu(u) {
    const p = u.pathname.replace(/\/+$/, '');
    if (!p) return 'index.html';
    const son = p.split('/').pop();
    if (!son.includes('.')) return p.slice(1) + '/index.html';
    return p.slice(1).replace(/\.[^./]+$/, '.html');
  }

  const sayfaParse = (html) => new DOMParser().parseFromString(html, 'text/html');

  /* --------------------------------------------------------------- köprü */

  async function jinaAl(href, html) {
    for (let deneme = 0; deneme < 2; deneme++) {
      try {
        const c = await fetch(JINA + href, {
          headers: html ? { 'X-Return-Format': 'html' } : {},
          signal: zaman(45000),
        });
        if (c.status === 429) { await bekle(2500); continue; }
        if (!c.ok) return null;
        let t = await c.text();
        if (/Warning: Target URL returned error/i.test(t.slice(0, 600))) return null;
        if (!html) {
          const i = t.indexOf('Markdown Content:');
          if (i >= 0) t = t.slice(i + 'Markdown Content:'.length).replace(/^\r?\n/, '');
        }
        return t;
      } catch (_) {
        await bekle(1200);
      }
    }
    return null;
  }

  async function metinAl(href, html) {
    try {
      const c = await fetch(href, { mode: 'cors', signal: zaman(18000) });
      if (c.ok) return await c.text();
    } catch (_) { /* CORS ya da ağ */ }

    const j = await jinaAl(href, html);
    if (j != null) return j;

    try {
      const c = await fetch(ALLORIGINS + encodeURIComponent(href), { signal: zaman(15000) });
      if (c.ok) return await c.text();
    } catch (_) { }

    return null;
  }

  async function ikiliAl(href) {
    const urlExt = uzanti(new URL(href));

    try {
      const c = await fetch(href, { mode: 'cors', signal: zaman(20000) });
      if (c.ok) {
        const blob = await c.blob();
        if (blob.size && blob.size <= DOSYA_LIMIT) {
          return { blob, ext: tipUzanti(blob.type) || urlExt || 'bin' };
        }
      }
    } catch (_) { }

    for (let deneme = 0; deneme < 2; deneme++) {
      try {
        const c = await fetch(WSRV + encodeURIComponent(href), { signal: zaman(25000) });
        if (!c.ok) { await bekle(800 + deneme * 1200); continue; }
        const blob = await c.blob();
        if (!blob.size || blob.size > DOSYA_LIMIT) return null;
        const ext = tipUzanti(blob.type);
        if (!ext) return null;
        return { blob, ext: ext === 'ico' ? 'png' : ext };
      } catch (_) {
        await bekle(800 + deneme * 1200);
      }
    }
    return null;
  }

  async function varlikAl(href) {
    const ext = uzanti(new URL(href));
    if (ATLA_UZANTI.has(ext)) return null;

    if (IKILI_UZANTI.has(ext)) return ikiliAl(href);

    if (METIN_UZANTI.has(ext)) {
      const metin = await metinAl(href, false);
      return metin == null ? null : { metin, ext };
    }

    return null;
  }

  /* ------------------------------------------------------- varlık toplama */

  function varliklariTopla(doc, sayfaUrl, kok, jsKoru) {
    const set = new Map();

    const ekle = (deger, temel, disari) => {
      if (!deger) return;
      let u;
      try { u = new URL(deger.trim(), temel); } catch (_) { return; }
      if (u.protocol !== 'http:' && u.protocol !== 'https:') return;
      if (ATLA_UZANTI.has(uzanti(u))) return;
      if (disari && u.origin !== kok) return;
      const k = anahtar(u);
      if (!set.has(k)) set.set(k, u.href);
    };

    const ekleSrcset = (deger, temel, disari) => {
      if (!deger) return;
      deger.split(',').forEach((parca) => {
        const parcalar = parca.trim().split(/\s+/);
        if (parcalar[0]) ekle(parcalar[0], temel, disari);
      });
    };

    doc.querySelectorAll('link[href]').forEach((e) => {
      const rel = (e.getAttribute('rel') || '').toLowerCase();
      if (rel.includes('stylesheet') || rel.includes('icon') || rel.includes('manifest')) {
        ekle(e.getAttribute('href'), sayfaUrl, !rel.includes('stylesheet'));
      }
    });
    doc.querySelectorAll('script[src]').forEach((e) => { if (jsKoru) ekle(e.getAttribute('src'), sayfaUrl, true); });
    doc.querySelectorAll('img[src]').forEach((e) => ekle(e.getAttribute('src'), sayfaUrl, false));
    doc.querySelectorAll('img[srcset]').forEach((e) => ekleSrcset(e.getAttribute('srcset'), sayfaUrl, false));
    doc.querySelectorAll('source[src]').forEach((e) => ekle(e.getAttribute('src'), sayfaUrl, false));
    doc.querySelectorAll('source[srcset]').forEach((e) => ekleSrcset(e.getAttribute('srcset'), sayfaUrl, false));
    doc.querySelectorAll('video[poster]').forEach((e) => ekle(e.getAttribute('poster'), sayfaUrl, false));
    doc.querySelectorAll('object[data]').forEach((e) => ekle(e.getAttribute('data'), sayfaUrl, false));
    doc.querySelectorAll('embed[src]').forEach((e) => ekle(e.getAttribute('src'), sayfaUrl, false));
    doc.querySelectorAll('input[type=image][src]').forEach((e) => ekle(e.getAttribute('src'), sayfaUrl, false));

    doc.querySelectorAll('[style]').forEach((e) => {
      cssUrlBul(e.getAttribute('style')).forEach((d) => ekle(d, sayfaUrl, false));
    });
    doc.querySelectorAll('style').forEach((e) => {
      cssUrlBul(e.textContent).forEach((d) => ekle(d, sayfaUrl, false));
    });

    return set;
  }

  function cssUrlBul(metin) {
    const liste = [];
    if (!metin) return liste;
    metin.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi, (m, q, d) => { liste.push(d); return m; });
    metin.replace(/@import\s+(['"])([^'"]+)\1/gi, (m, q, d) => { liste.push(d); return m; });
    return liste;
  }

  /* ------------------------------------------------------------- yeniden yaz */

  function cevir(deger, temel, kaynakYol, kok, yollarA) {
    if (!deger) return null;
    const d = deger.trim();
    if (!d || /^(data:|blob:|mailto:|tel:|javascript:|#)/i.test(d)) return null;
    let u;
    try { u = new URL(d, temel); } catch (_) { return null; }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;

    const y = yollarA.get(anahtar(u));
    if (y) return goreliYol(y, kaynakYol);
    if (u.origin === kok) return u.href;   // indirilemedi → çevrimiçi çalışsın
    return null;
  }

  function cssCevir(metin, temel, kaynakYol, kok, yollarA) {
    if (!metin) return metin;
    let s = metin.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi, (m, q, d) => {
      const y = cevir(d, temel, kaynakYol, kok, yollarA);
      return y ? `url(${q}${y}${q})` : m;
    });
    s = s.replace(/@import\s+(['"])([^'"]+)\1/gi, (m, q, d) => {
      const y = cevir(d, temel, kaynakYol, kok, yollarA);
      return y ? `@import ${q}${y}${q}` : m;
    });
    return s;
  }

  function srcsetCevir(deger, temel, kaynakYol, kok, yollarA) {
    if (!deger) return null;
    return deger.split(',').map((parca) => {
      const p = parca.trim().split(/\s+/);
      if (!p[0]) return parca.trim();
      const y = cevir(p[0], temel, kaynakYol, kok, yollarA);
      return [y || p[0], ...p.slice(1)].join(' ');
    }).join(', ');
  }

  function htmlCevir(html, sayfaUrl, sayfaYoluStr, kok, sayfaYollari, yollarA, jsKoru) {
    const doc = sayfaParse(html);
    const baseEl = doc.querySelector('base[href]');
    const temel = baseEl ? new URL(baseEl.getAttribute('href'), sayfaUrl).href : sayfaUrl;

    // SPA'lar açılışta DOM'u kendi API'sinden yeniden kurar; çevrimdışı kopyada
    // sayfa boş kalmasın diye betikler varsayılan olarak çıkarılır.
    if (!jsKoru) doc.querySelectorAll('script').forEach((e) => e.remove());

    const nitelikler = [
      ['link[href]', 'href'], ['script[src]', 'src'], ['img[src]', 'src'],
      ['source[src]', 'src'], ['video[src]', 'src'], ['audio[src]', 'src'],
      ['video[poster]', 'poster'], ['embed[src]', 'src'], ['object[data]', 'data'],
      ['input[type=image][src]', 'src'], ['track[src]', 'src'],
    ];
    for (const [sec, nit] of nitelikler) {
      doc.querySelectorAll(sec).forEach((e) => {
        const y = cevir(e.getAttribute(nit), temel, sayfaYoluStr, kok, yollarA);
        if (y) e.setAttribute(nit, y);
      });
    }

    doc.querySelectorAll('[srcset]').forEach((e) => {
      const y = srcsetCevir(e.getAttribute('srcset'), temel, sayfaYoluStr, kok, yollarA);
      if (y) e.setAttribute('srcset', y);
    });

    doc.querySelectorAll('[style]').forEach((e) => {
      e.setAttribute('style', cssCevir(e.getAttribute('style'), temel, sayfaYoluStr, kok, yollarA));
    });
    doc.querySelectorAll('style').forEach((e) => {
      e.textContent = cssCevir(e.textContent, temel, sayfaYoluStr, kok, yollarA);
    });

    doc.querySelectorAll('a[href]').forEach((e) => {
      const href = e.getAttribute('href');
      if (!href || /^(mailto:|tel:|javascript:|#)/i.test(href)) return;
      let u;
      try { u = new URL(href, temel); } catch (_) { return; }
      if (u.origin !== kok) return;
      const hedef = sayfaYollari.get(anahtar(u));
      if (hedef) e.setAttribute('href', goreliYol(hedef, sayfaYoluStr) + (u.hash || ''));
    });

    if (baseEl) baseEl.remove();
    return '<!DOCTYPE html>\n' + doc.documentElement.outerHTML;
  }

  /* ------------------------------------------------------------------ zip */

  const CRC_TABLO = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();

  function crc32(veri) {
    let c = 0xFFFFFFFF;
    for (let i = 0; i < veri.length; i++) c = CRC_TABLO[(c ^ veri[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  }

  function zipYap(dosyalar) {
    const parcalar = [];
    const merkez = [];
    const d = new Date();
    const saat = ((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) & 0xFFFF;
    const gun = (((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xFFFF;
    let ofset = 0;

    for (const dosya of dosyalar) {
      const ad = enc.encode(dosya.ad);
      const crc = crc32(dosya.veri);
      const boy = dosya.veri.length;

      const yerel = new Uint8Array(30 + ad.length);
      const yv = new DataView(yerel.buffer);
      yv.setUint32(0, 0x04034b50, true);
      yv.setUint16(4, 20, true);
      yv.setUint16(6, 0x0800, true);
      yv.setUint16(8, 0, true);
      yv.setUint16(10, saat, true);
      yv.setUint16(12, gun, true);
      yv.setUint32(14, crc, true);
      yv.setUint32(18, boy, true);
      yv.setUint32(22, boy, true);
      yv.setUint16(26, ad.length, true);
      yv.setUint16(28, 0, true);
      yerel.set(ad, 30);

      parcalar.push(yerel, dosya.veri);

      const kayit = new Uint8Array(46 + ad.length);
      const kv = new DataView(kayit.buffer);
      kv.setUint32(0, 0x02014b50, true);
      kv.setUint16(4, 20, true);
      kv.setUint16(6, 20, true);
      kv.setUint16(8, 0x0800, true);
      kv.setUint16(10, 0, true);
      kv.setUint16(12, saat, true);
      kv.setUint16(14, gun, true);
      kv.setUint32(16, crc, true);
      kv.setUint32(20, boy, true);
      kv.setUint32(24, boy, true);
      kv.setUint16(28, ad.length, true);
      kv.setUint32(42, ofset, true);
      kayit.set(ad, 46);
      merkez.push(kayit);

      ofset += yerel.length + boy;
    }

    const merkezBoy = merkez.reduce((t, k) => t + k.length, 0);
    const son = new Uint8Array(22);
    const sv = new DataView(son.buffer);
    sv.setUint32(0, 0x06054b50, true);
    sv.setUint16(8, dosyalar.length, true);
    sv.setUint16(10, dosyalar.length, true);
    sv.setUint32(12, merkezBoy, true);
    sv.setUint32(16, ofset, true);

    return new Blob([...parcalar, ...merkez, son], { type: 'application/zip' });
  }

  /* -------------------------------------------------------------- kopyalama */

  async function kopyala(girdi, sayfaAdet, jsKoru, bildir) {
    const baslangic = new URL(girdi);
    const kok = baslangic.origin;

    const sayfalar = new Map();      // anahtar -> {url, html, yol}
    const sayfaYollari = new Map();  // anahtar -> 'rehber/index.html'
    const kuyruk = [baslangic.href];
    const gorulen = new Set([anahtar(baslangic)]);

    sayfaYollari.set(anahtar(baslangic), sayfaYolu(baslangic));

    // ---- 1) sayfalar
    while (kuyruk.length && sayfalar.size < sayfaAdet) {
      const parti = kuyruk.splice(0, 2);
      const sonuclar = await Promise.all(parti.map(async (href) => {
        try {
          const html = await metinAl(href, true);
          return html ? { url: new URL(href), html } : null;
        } catch (_) {
          return null;
        }
      }));

      for (const s of sonuclar) {
        if (!s) continue;
        const k = anahtar(s.url);
        if (sayfalar.has(k)) continue;

        let yol = sayfaYollari.get(k) || sayfaYolu(s.url);
        if ([...sayfalar.values()].some((x) => x.yol === yol)) yol = yol.replace(/\.html$/, '-' + kisaHash(k) + '.html');
        sayfaYollari.set(k, yol);
        sayfalar.set(k, { url: s.url, html: s.html, yol });

        const doc = sayfaParse(s.html);
        doc.querySelectorAll('a[href]').forEach((a) => {
          const href = a.getAttribute('href');
          if (!href || /^(mailto:|tel:|javascript:|#)/i.test(href)) return;
          let u;
          try { u = new URL(href, s.url); } catch (_) { return; }
          if (u.origin !== kok) return;
          if (ATLA_UZANTI.has(uzanti(u))) return;
          const ak = anahtar(u);
          if (gorulen.has(ak)) return;
          gorulen.add(ak);
          sayfaYollari.set(ak, sayfaYolu(u));
          kuyruk.push(u.href);
        });
      }

      bildir({ asama: 'sayfa', sayfa: sayfalar.size, toplam: sayfaAdet });
    }

    if (!sayfalar.size) throw new Error('Sayfa indirilemedi — adres yanlış olabilir ya da site erişimi engelliyor.');

    // ---- 2) dosyalar
    const varliklar = new Map();   // anahtar -> {metin}|{blob, ext}
    const islenen = new Set();
    const vKuyruk = new Map();     // anahtar -> href

    for (const s of sayfalar.values()) {
      const doc = sayfaParse(s.html);
      varliklariTopla(doc, s.url.href, kok, jsKoru).forEach((href, k) => {
        if (!vKuyruk.has(k)) vKuyruk.set(k, href);
      });
    }

    let sayac = 0;
    const basarisiz = new Map();

    const partiIsle = async (parti) => {
      await Promise.all(parti.map(async ([k, href]) => {
        if (islenen.has(k)) return;
        islenen.add(k);
        const v = await varlikAl(href);
        if (!v) { basarisiz.set(k, href); return; }
        basarisiz.delete(k);
        varliklar.set(k, v);
        sayac++;
        bildir({ asama: 'dosya', dosya: sayac, sayfa: sayfalar.size, toplam: sayfaAdet });

        if (v.metin != null && v.ext === 'css') {
          const cssUrl = new URL(k);
          cssUrlBul(v.metin).forEach((d) => {
            let u;
            try { u = new URL(d, cssUrl); } catch (_) { return; }
            if (u.protocol !== 'http:' && u.protocol !== 'https:') return;
            if (u.origin !== kok) return;
            if (ATLA_UZANTI.has(uzanti(u))) return;
            const ak = anahtar(u);
            if (!islenen.has(ak) && !vKuyruk.has(ak)) vKuyruk.set(ak, u.href);
          });
        }
      }));
    };

    while (vKuyruk.size && varliklar.size < VARLIK_LIMIT) {
      const parti = [...vKuyruk.entries()].slice(0, 4);
      for (const [k] of parti) vKuyruk.delete(k);
      await partiIsle(parti);
    }

    // indirilemeyen dosyalar için tek tur daha
    if (basarisiz.size) {
      const tekrar = [...basarisiz.entries()].slice(0, 60);
      basarisiz.clear();
      for (const [k] of tekrar) islenen.delete(k);
      for (let i = 0; i < tekrar.length; i += 2) {
        await partiIsle(tekrar.slice(i, i + 2));
        await bekle(400);
      }
    }

    // ---- 3) yollar + yeniden yaz
    const yollarA = new Map();
    for (const [k, v] of varliklar) {
      const u = new URL(k);
      const ham = (u.pathname.split('/').pop() || 'dosya').replace(/\.[^.]+$/, '');
      const temiz = ham.replace(/[^a-zA-Z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 32) || 'dosya';
      yollarA.set(k, `_dosyalar/${temiz}-${kisaHash(k)}.${v.ext}`);
    }

    const dosyalar = [];
    for (const s of sayfalar.values()) {
      const html = htmlCevir(s.html, s.url.href, s.yol, kok, sayfaYollari, yollarA, jsKoru);
      dosyalar.push({ ad: s.yol, veri: enc.encode(html) });
    }

    for (const [k, v] of varliklar) {
      const yol = yollarA.get(k);
      if (!yol) continue;
      if (v.metin != null) {
        const metin = v.ext === 'css' ? cssCevir(v.metin, new URL(k).href, yol, kok, yollarA) : v.metin;
        dosyalar.push({ ad: yol, veri: enc.encode(metin) });
      } else {
        dosyalar.push({ ad: yol, veri: new Uint8Array(await v.blob.arrayBuffer()) });
      }
    }

    const kunye = [
      'sitecopy',
      'kaynak: ' + baslangic.href,
      'tarih: ' + new Date().toLocaleString('tr-TR'),
      'sayfa: ' + sayfalar.size,
      'dosya: ' + (dosyalar.length - sayfalar.size),
      '',
      'Kullanım: ZIP\'i aç, index.html dosyasına çift tıkla.',
    ].join('\n');
    dosyalar.push({ ad: 'BENIOKU.txt', veri: enc.encode(kunye) });

    const blob = zipYap(dosyalar);
    return {
      blob,
      dosyaSayisi: dosyalar.length,
      sayfaSayisi: sayfalar.size,
      ad: `${baslangic.hostname.replace(/^www\./, '')}-sitecopy.zip`,
    };
  }

  /* ------------------------------------------------------------------- ui */

  function indir(blob, ad) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = ad;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 120000);
    return url;
  }

  el.form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (calisiyor) return;

    let url = el.url.value.trim();
    if (!url) return;
    if (!/^https?:\/\//i.test(url)) url = 'https://' + url;

    let hedef;
    try {
      hedef = new URL(url);
      if (hedef.protocol !== 'http:' && hedef.protocol !== 'https:') throw new Error();
    } catch (_) {
      tost('Geçerli bir adres yaz');
      return;
    }

    const adet = Number(el.sayfa.value) || 10;
    calisiyor = true;
    el.dugme.disabled = true;
    el.basari.style.display = 'none';
    el.durumKarti.style.display = 'block';
    el.konsol.innerHTML = '';
    el.konsol.style.display = 'block';
    el.cubuk.style.width = '2%';
    el.kisaBilgi.textContent = hedef.hostname;
    rozet('calisiyor', 'Kopyalanıyor');
    yaz(`  ${hedef.href} — en fazla ${adet} sayfa`, 'sol');

    const bildir = (d) => {
      if (d.asama === 'sayfa') {
        el.cubuk.style.width = Math.min(75, 5 + (d.sayfa / Math.max(1, d.toplam)) * 45) + '%';
        el.rozetMetin.textContent = `Sayfalar · ${d.sayfa}/${d.toplam}`;
        el.kisaBilgi.textContent = `${hedef.hostname} · dosyalar sırada`;
      } else if (d.asama === 'dosya') {
        el.cubuk.style.width = Math.min(95, 50 + (d.dosya / 200) * 45) + '%';
        el.rozetMetin.textContent = `Dosyalar · ${d.dosya}`;
      }
    };

    try {
      const sonuc = await kopyala(hedef.href, adet, el.js.checked, bildir);
      el.cubuk.style.width = '100%';
      rozet('bitti', 'Bitti');
      el.kisaBilgi.textContent = `${sonuc.sayfaSayisi} sayfa · ${sonuc.dosyaSayisi} dosya`;

      const url2 = indir(sonuc.blob, sonuc.ad);
      el.basari.style.display = 'block';
      el.basariBilgi.textContent =
        `${sonuc.sayfaSayisi} sayfa, ${sonuc.dosyaSayisi} dosya · ` +
        `${(sonuc.blob.size / 1048576).toFixed(1)} MB · ZIP açıp index.html'e çift tıkla.`;
      el.basariAdres.textContent = sonuc.ad;
      el.basariAdres.href = url2;
      el.basariAdres.setAttribute('download', sonuc.ad);
      el.btnIndir.onclick = () => indir(sonuc.blob, sonuc.ad);
      el.basari.scrollIntoView({ behavior: 'smooth', block: 'nearest' });

      yaz(`  ✓ ${sonuc.sayfaSayisi} sayfa, ${sonuc.dosyaSayisi} dosya indirildi`, 'ok');
      tost('Kopya hazır — ZIP indiriliyor');
    } catch (hata) {
      rozet('hata', 'Hata');
      yaz('✗ ' + (hata && hata.message ? hata.message : hata), 'hata');
      tost('Kopyalama tamamlanamadı');
    } finally {
      calisiyor = false;
      el.dugme.disabled = false;
    }
  });

  /* ----------------------------------------------------------------- tema */

  const temaUygula = (acik) => {
    document.body.classList.toggle('acik', acik);
    el.temaBtn.textContent = acik ? 'siyah' : 'beyaz';
    localStorage.setItem('sitecopy_tema', acik ? 'acik' : 'koyu');
  };
  temaUygula(localStorage.getItem('sitecopy_tema') === 'acik');
  el.temaBtn.addEventListener('click', () => temaUygula(!document.body.classList.contains('acik')));
})();
