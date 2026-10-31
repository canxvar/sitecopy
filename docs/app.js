/* sitecopy paneli — GitHub Pages sürümü
 *
 * Panelin kendisi sunucu değildir: kopyalama işini deponun GitHub Actions'ı yapar.
 * Bu dosya adresi panoya kopyalar, Actions sayfasını açar ve sonuçları listeler.
 * Hiçbir jeton/hesap gerekmez; her şey herkese açık GitHub API'sinden okunur.
 */
(() => {
  'use strict';

  const SAHIP = 'canxvar';
  const DEPO = 'sitecopy';
  const API = 'https://api.github.com';
  const TABAN = new URL('./', location.href).pathname;
  const EYLEMLER = `https://github.com/${SAHIP}/${DEPO}/actions`;
  const IS_AKISI = `${EYLEMLER}/workflows/kopyala.yml`;

  const $ = (id) => document.getElementById(id);
  const el = {
    form: $('form'), url: $('url'), dugme: $('dugme'),
    liste: $('liste'), listeSayac: $('listeSayac'), btnYenile: $('btnYenile'),
    isler: $('isler'), tost: $('tost'), temaBtn: $('temaBtn'),
  };

  /* ------------------------------------------------------------- yardımcı */

  function tost(mesaj) {
    el.tost.textContent = mesaj;
    el.tost.classList.add('gor');
    clearTimeout(tost._z);
    tost._z = setTimeout(() => el.tost.classList.remove('gor'), 3600);
  }

  const kacis = (s) => String(s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));

  async function gh(yol) {
    const cevap = await fetch(API + yol, { headers: { Accept: 'application/vnd.github+json' } });
    if (cevap.status === 404) return null;
    if (!cevap.ok) {
      const hata = new Error(`GitHub ${cevap.status}`);
      hata.durum = cevap.status;
      throw hata;
    }
    return cevap.json();
  }

  function tarih(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return '';
    const p = (n) => String(n).padStart(2, '0');
    return `${p(d.getDate())}.${p(d.getMonth() + 1)}.${d.getFullYear()} ` +
           `${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  /* --------------------------------------------------------------- kopyala */

  let isAkisiVar = false;

  // İş akışı depoda varsa doğrudan onun sayfasını, yoksa Actions listesini aç.
  async function isAkisiKontrol() {
    try {
      const veri = await gh(`/repos/${SAHIP}/${DEPO}/actions/workflows`);
      isAkisiVar = ((veri && veri.workflows) || [])
        .some((w) => (w.path || '').endsWith('workflows/kopyala.yml'));
    } catch (_) {
      isAkisiVar = false;
    }
  }

  el.form.addEventListener('submit', async (e) => {
    e.preventDefault();

    let url = el.url.value.trim();
    if (!url) return;
    if (!/^https?:\/\//i.test(url)) url = 'https://' + url;
    el.url.value = url;

    // Pencere, tarayıcı engellemesin diye tıklamanın içinde (senkron) açılır.
    const pencere = window.open(isAkisiVar ? IS_AKISI : EYLEMLER, '_blank', 'noopener');

    try {
      await navigator.clipboard.writeText(url);
      tost('Adres panoya kopyalandı');
    } catch (_) {
      el.url.focus();
      el.url.select();
      tost('Adres seçildi — kopyalamak için kopyala (⌘/Ctrl+C)');
    }

    if (!pencere) tost('Pencere engellendi — Actions sayfasını kendin aç');
  });

  /* ---------------------------------------------------------------- liste */

  async function kopyalariYukle() {
    try {
      const icerik = await gh(`/repos/${SAHIP}/${DEPO}/contents/docs/kopyalar`);
      const klasorler = (Array.isArray(icerik) ? icerik : [])
        .filter((x) => x.type === 'dir')
        .sort((a, b) => (a.name < b.name ? 1 : -1));

      el.listeSayac.textContent = klasorler.length ? `${klasorler.length} kopya` : '';

      if (!klasorler.length) {
        el.liste.innerHTML = '<div class="bos">Henüz kopya yok.</div>';
        return;
      }

      el.liste.innerHTML = klasorler.map((k) => {
        const adres = `${TABAN}kopyalar/${encodeURIComponent(k.name)}/`;
        return '<div class="satir">' +
          `<span class="ad"><a class="link" href="${adres}">${kacis(k.name)}</a></span>` +
          '<span class="meta"></span>' +
          '<span class="eylem">' +
            `<a class="link" href="${adres}">aç</a>` +
            `<a class="link" href="https://github.com/${SAHIP}/${DEPO}/tree/main/docs/kopyalar/${encodeURIComponent(k.name)}" target="_blank" rel="noopener">dosyalar</a>` +
          '</span>' +
        '</div>';
      }).join('');
    } catch (hata) {
      el.listeSayac.textContent = '';
      el.liste.innerHTML = `<div class="bos">Kopyalar alınamadı (${kacis(hata.message)}).</div>`;
    }
  }

  /* ------------------------------------------------------------- son işler */

  const DURUM = {
    queued: 'sırada', waiting: 'sırada', in_progress: 'çalışıyor',
    completed: 'bitti', requested: 'istendi', pending: 'bekliyor',
  };
  const SONUC = {
    success: 'başarılı', failure: 'hata', cancelled: 'iptal', skipped: 'atlandı',
  };

  async function isleriYukle() {
    try {
      const veri = await gh(`/repos/${SAHIP}/${DEPO}/actions/runs?per_page=8&event=workflow_dispatch`);
      const kosular = (veri && veri.workflow_runs) || [];

      if (!kosular.length) {
        el.isler.innerHTML = '<div class="bos">Henüz iş yok.</div>';
        return;
      }

      el.isler.innerHTML = kosular.map((r) => {
        const canli = r.status === 'in_progress' || r.status === 'queued';
        const ad = r.display_title || r.name || 'iş';
        const durum = SONUC[r.conclusion] || DURUM[r.status] || r.status || '';
        return '<div class="satir">' +
          `<span class="ad"><span class="nokta${canli ? ' calisiyor' : ''}"></span>${kacis(ad)}</span>` +
          `<span class="meta">${tarih(r.created_at)} · ${kacis(durum)}</span>` +
          '<span class="eylem">' +
            `<a class="link" href="${r.html_url}" target="_blank" rel="noopener">github</a>` +
          '</span>' +
        '</div>';
      }).join('');
    } catch (hata) {
      el.isler.innerHTML = `<div class="bos">İşler alınamadı (${kacis(hata.message)}).</div>`;
    }
  }

  function yenile() {
    isAkisiKontrol();
    kopyalariYukle();
    isleriYukle();
  }

  el.btnYenile.addEventListener('click', yenile);

  /* --------------------------------------------------------------- tema */

  const temaUygula = (acik) => {
    document.body.classList.toggle('acik', acik);
    el.temaBtn.textContent = acik ? 'siyah' : 'beyaz';
    localStorage.setItem('sitecopy_tema', acik ? 'acik' : 'koyu');
  };
  temaUygula(localStorage.getItem('sitecopy_tema') === 'acik');
  el.temaBtn.addEventListener('click', () => temaUygula(!document.body.classList.contains('acik')));

  /* ---------------------------------------------------------------- başla */

  yenile();
  // sekme tekrar görünür olduğunda listeyi tazele
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) yenile();
  });
})();
