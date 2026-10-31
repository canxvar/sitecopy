/* sitecopy paneli — GitHub Pages sürümü
 * Kopyalama işini deponun Actions'ı yapar; bu dosya yalnızca arayüz + tetikleme.
 */
(() => {
  'use strict';

  const SAHIP = 'canxvar';
  const DEPO = 'sitecopy';
  const API = 'https://api.github.com';
  const TABAN = new URL('./', location.href).pathname;
  const JETON_ANAHTAR = 'sitecopy_token';

  const $ = (id) => document.getElementById(id);
  const el = {
    form: $('form'), url: $('url'), sayfa: $('sayfa'), dugme: $('dugme'),
    jetonNokta: $('jetonNokta'), jetonDurum: $('jetonDurum'), jetonBtn: $('jetonBtn'),
    jetonKart: $('jetonKart'), jetonGirdi: $('jetonGirdi'), jetonKaydet: $('jetonKaydet'),
    jetonSil: $('jetonSil'),
    durumKarti: $('durumKarti'), rozet: $('rozet'), rozetMetin: $('rozetMetin'),
    kisaBilgi: $('kisaBilgi'), ilerleme: $('ilerleme'), konsol: $('konsol'),
    basari: $('basari'), basariBilgi: $('basariBilgi'), basariAdres: $('basariAdres'),
    btnAc: $('btnAc'), btnKlasor: $('btnKlasor'),
    liste: $('liste'), listeSayac: $('listeSayac'), btnYenile: $('btnYenile'),
    tost: $('tost'), temaBtn: $('temaBtn'),
  };

  let aktifKim = null;
  let aktifUrl = null;
  let sayac = null;
  let foto = null;

  /* ------------------------------------------------------------- yardımcı */

  const jeton = () => localStorage.getItem(JETON_ANAHTAR) || '';

  function tost(mesaj) {
    el.tost.textContent = mesaj;
    el.tost.classList.add('gor');
    clearTimeout(tost._z);
    tost._z = setTimeout(() => el.tost.classList.remove('gor'), 3200);
  }

  function yaz(satir, tur = '') {
    const d = document.createElement('div');
    if (tur) d.className = tur;
    d.textContent = satir;
    el.konsol.appendChild(d);
    while (el.konsol.children.length > 300) el.konsol.removeChild(el.konsol.firstChild);
    el.konsol.scrollTop = el.konsol.scrollHeight;
  }

  function rozet(durum) {
    el.rozet.className = 'rozet ' + durum;
    el.rozetMetin.textContent = {
      bekliyor: 'Sırada', calisiyor: 'Çalışıyor', bitti: 'Bitti', hata: 'Hata',
    }[durum] || durum;
    el.ilerleme.style.display = durum === 'calisiyor' || durum === 'bekliyor' ? 'block' : 'none';
  }

  async function gh(yol, secenek = {}) {
    const basliklar = { Accept: 'application/vnd.github+json', ...(secenek.headers || {}) };
    const t = jeton();
    if (t) basliklar.Authorization = `Bearer ${t}`;
    if (secenek.body) basliklar['Content-Type'] = 'application/json';
    const cevap = await fetch(API + yol, { ...secenek, headers: basliklar });
    if (!cevap.ok) {
      let ayrinti = '';
      try { ayrinti = (await cevap.text()).slice(0, 300); } catch (_) {}
      const hata = new Error(`${cevap.status}${ayrinti ? ' — ' + ayrinti : ''}`);
      hata.durum = cevap.status;
      throw hata;
    }
    return cevap.status === 204 ? null : cevap.json();
  }

  const bekle = (ms) => new Promise((r) => setTimeout(r, ms));

  function kimUret() {
    const d = new Date();
    const p = (n, u = 2) => String(n).padStart(u, '0');
    const zaman = `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}` +
                  `-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
    const rastgele = Math.random().toString(16).slice(2, 6);
    return `${zaman}-${rastgele}`;
  }

  function kimTarih(kim) {
    const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/.exec(kim);
    if (!m) return '';
    const [, y, a, g, s, dk] = m;
    return `${g}.${a}.${y} ${s}:${dk}`;
  }

  /* --------------------------------------------------------------- jeton */

  function jetonDurumCiz() {
    const var_ = !!jeton();
    el.jetonNokta.style.opacity = var_ ? '1' : '.25';
    el.jetonDurum.textContent = var_
      ? `GitHub jetonu tanımlı (…${jeton().slice(-4)})`
      : 'GitHub jetonu yok — kopyalama kapalı';
    el.jetonDurum.className = var_ ? '' : 'kapali';
    el.jetonBtn.textContent = var_ ? 'değiştir' : 'jeton ekle';
  }

  el.jetonBtn.addEventListener('click', () => {
    const acik = el.jetonKart.style.display === 'block';
    el.jetonKart.style.display = acik ? 'none' : 'block';
    if (!acik) {
      el.jetonGirdi.value = '';
      el.jetonGirdi.placeholder = jeton() ? `mevcut: …${jeton().slice(-4)}` : 'ghp_...';
      el.jetonGirdi.focus();
    }
  });

  el.jetonKaydet.addEventListener('click', () => {
    const deger = el.jetonGirdi.value.trim();
    if (!/^(ghp_|github_pat_)/.test(deger)) {
      tost('Jeton ghp_ veya github_pat_ ile başlamalı');
      return;
    }
    localStorage.setItem(JETON_ANAHTAR, deger);
    el.jetonKart.style.display = 'none';
    jetonDurumCiz();
    tost('Jeton kaydedildi');
    listele();
  });

  el.jetonSil.addEventListener('click', () => {
    localStorage.removeItem(JETON_ANAHTAR);
    el.jetonKart.style.display = 'none';
    jetonDurumCiz();
    tost('Jeton kaldırıldı');
  });

  /* --------------------------------------------------------------- tema */

  const temaUygula = (acik) => {
    document.body.classList.toggle('acik', acik);
    el.temaBtn.textContent = acik ? 'siyah' : 'beyaz';
    localStorage.setItem('sitecopy_tema', acik ? 'acik' : 'koyu');
  };
  temaUygula(localStorage.getItem('sitecopy_tema') === 'acik');
  el.temaBtn.addEventListener('click', () => temaUygula(!document.body.classList.contains('acik')));

  /* -------------------------------------------------------------- kopyala */

  el.form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!jeton()) {
      tost('Önce GitHub jetonu ekle');
      el.jetonKart.style.display = 'block';
      el.jetonGirdi.focus();
      return;
    }

    let url = el.url.value.trim();
    if (!url) return;
    if (!/^https?:\/\//i.test(url)) url = 'https://' + url;

    const sayfa = el.sayfa.value;
    const kim = kimUret();
    aktifKim = kim;
    aktifUrl = url;

    el.dugme.disabled = true;
    el.konsol.innerHTML = '';
    el.konsol.style.display = 'block';
    el.durumKarti.style.display = 'block';
    el.basari.style.display = 'none';
    el.kisaBilgi.textContent = url;
    rozet('bekliyor');
    yaz(`  · ${url} — ${sayfa} sayfa`, 'sol');

    try {
      await gh(`/repos/${SAHIP}/${DEPO}/actions/workflows/kopyala.yml/dispatches`, {
        method: 'POST',
        body: JSON.stringify({
          ref: 'main',
          inputs: { url, kim, sayfa: String(sayfa), derinlik: '6' },
        }),
      });
      yaz('  ✓ İş GitHub Actions kuyruğuna eklendi', 'ok');
      rozet('calisiyor');
      izle(kim);
    } catch (hata) {
      rozet('hata');
      el.dugme.disabled = false;
      yaz('✗ ' + hata.message, 'hata');
      tost('İş başlatılamadı — jeton yetkisini kontrol et');
    }
  });

  function izle(kim) {
    clearInterval(sayac);
    const baslangic = Date.now();

    const bak = async () => {
      if (aktifKim !== kim) return;
      try {
        const liste = await gh(`/repos/${SAHIP}/${DEPO}/actions/runs?per_page=30&event=workflow_dispatch`);
        const kosu = (liste.workflow_runs || []).find((r) => (r.name || '').includes(kim));
        const gecen = Math.round((Date.now() - baslangic) / 1000);

        if (!kosu) {
          el.kisaBilgi.textContent = `${aktifUrl} · ${gecen}sn`;
          return;
        }

        if (kosu.status === 'queued' || kosu.status === 'waiting') {
          rozet('bekliyor');
          el.kisaBilgi.textContent = `${aktifUrl} · sırada`;
        } else if (kosu.status === 'in_progress') {
          rozet('calisiyor');
          el.kisaBilgi.textContent = `${aktifUrl} · ${gecen}sn`;
        } else {
          clearInterval(sayac);
          el.dugme.disabled = false;
          if (kosu.conclusion === 'success') {
            rozet('bitti');
            bitir(kim, kosu);
          } else {
            rozet('hata');
            yaz(`✗ İş ${kosu.conclusion} — ${kosu.html_url}`, 'hata');
            el.kisaBilgi.textContent = aktifUrl;
            tost('Kopyalama başarısız');
          }
          listele();
        }
      } catch (_) {
        /* ağ hatası: bir sonraki turda tekrar dene */
      }
    };

    sayac = setInterval(bak, 4000);
    bak();
  }

  function bitir(kim, kosu) {
    const adres = `${TABAN}kopyalar/${kim}/`;
    const tam = new URL(adres, location.href).href;
    el.basari.style.display = 'block';
    el.basariAdres.textContent = tam;
    el.basariAdres.href = adres;
    el.basariBilgi.textContent = 'GitHub Pages yayına alması birkaç saniye sürebilir.';
    el.btnAc.onclick = () => window.open(adres, '_blank', 'noopener');
    el.btnKlasor.onclick = () => window.open(
      `https://github.com/${SAHIP}/${DEPO}/tree/main/docs/kopyalar/${kim}`, '_blank', 'noopener');
    el.basari.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    yaz('  ✓ Kopya hazır: ' + adres, 'ok');
    if (foto === null) foto = true;
  }

  /* ---------------------------------------------------------------- liste */

  async function listele() {
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
        const adres = `${TABAN}kopyalar/${k.name}/`;
        const tarih = kimTarih(k.name);
        return '<div class="kopya">' +
          `<span class="alan"><a class="link" href="${adres}" target="_blank" rel="noopener">${k.name}</a></span>` +
          `<span class="meta">${tarih}</span>` +
          '<span class="eylem">' +
            `<a class="link" href="${adres}" target="_blank" rel="noopener">aç</a>` +
            `<button class="link" data-sil="${k.name}">sil</button>` +
          '</span>' +
        '</div>';
      }).join('');

      el.liste.querySelectorAll('[data-sil]').forEach((d) => {
        d.addEventListener('click', () => sil(d.dataset.sil));
      });
    } catch (hata) {
      if (hata.durum === 404) {
        el.listeSayac.textContent = '';
        el.liste.innerHTML = '<div class="bos">Henüz kopya yok.</div>';
        return;
      }
      el.liste.innerHTML = `<div class="bos">Liste alınamadı (${hata.message}).</div>`;
    }
  }

  async function sil(kim) {
    if (!jeton()) { tost('Silmek için jeton gerekli'); return; }
    if (!confirm(`"${kim}" kopyası silinsin mi?`)) return;
    try {
      await gh(`/repos/${SAHIP}/${DEPO}/actions/workflows/sil.yml/dispatches`, {
        method: 'POST',
        body: JSON.stringify({ ref: 'main', inputs: { kim } }),
      });
      tost('Silme işi başlatıldı');
      setTimeout(listele, 6000);
    } catch (hata) {
      tost('Silinemedi: ' + hata.message);
    }
  }

  el.btnYenile.addEventListener('click', listele);

  /* ---------------------------------------------------------------- başla */

  jetonDurumCiz();
  listele();
})();
