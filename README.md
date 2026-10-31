# sitecopy

Bir siteyi kopyalayıp kendi tarayıcında gezilebilir hale getiren aracın **online
paneli**. Sunucu yok, kurulum yok: panel GitHub Pages'te durur, kopyalama işini
deponun GitHub Actions'ı yapar, çıktı yine aynı adreste yayınlanır.

## Nasıl çalışır

```
GitHub Pages (docs/)          GitHub Actions              GitHub Pages
┌──────────────────┐  tetikle  ┌──────────────────┐  commit  ┌──────────────────┐
│  panel (tarayıcı)│ ────────► │ site_kopyala.rb  │ ───────► │ kopyalar/<kim>/  │
└──────────────────┘           └──────────────────┘          └──────────────────┘
```

1. Panelde adresi yazıp **Kopyala**'ya basarsın.
2. Panel, `kopyala` iş akışını `workflow_dispatch` ile tetikler.
3. Action `site_kopyala.rb`'yi çalıştırır, `pages_hazirla.rb` yolları Pages için
   göreli hale getirir, sonucu `docs/kopyalar/<kim>/` altına commit eder.
4. Pages yayına alır; panel `…/kopyalar/<kim>/` adresini gösterir.

## Gereken tek şey

Panelde bir kez **kişisel erişim jetonu** tanımlaman:
<https://github.com/settings/tokens/new?scopes=repo,workflow&description=sitecopy>

- `repo` + `workflow` yetkileri yeterli.
- Jeton yalnızca tarayıcının `localStorage`'ında tutulur, hiçbir sunucuya gitmez.
- Jetonsuz panel açılır, kopyalar listelenir ve gezilir; sadece yeni kopyalama ve
  silme kapalı olur.

## Pages ayarı

Depo → Settings → Pages → **Source: Deploy from a branch** → Branch: `main`,
klasör: **`/docs`**.

`docs/.nojekyll` sayesinde `_dis/` gibi alt çizgiyle başlayan klasörler de yayınlanır.

## Yerel kullanım (crawler'ı doğrudan çalıştırma)

```bash
bundle install
ruby site_kopyala.rb https://ornek.com -o cikti -d 4 -s 40
ruby pages_hazirla.rb cikti      # yolları göreli hale getirir
```

## Dosyalar

| Yol | İş |
|---|---|
| `docs/` | GitHub Pages paneli (statik) |
| `docs/kopyalar/` | Üretilen kopyalar |
| `.github/workflows/kopyala.yml` | Kopyalama iş akışı |
| `.github/workflows/sil.yml` | Kopya silme iş akışı |
| `site_kopyala.rb` | Crawler (Actions aynı dosyayı çalıştırır) |
| `pages_hazirla.rb` | Kök mutlak yolları Pages için göreli yapar |
| `Gemfile` | Actions'ta kurulan bağımlılıklar (`nokogiri`) |

## Sınırlar

- GitHub Actions ücretsiz kotası: ayda 2.000 dakika. Büyük siteler bu kotayı yer.
- Pages sitesi 1 GB'ı, tek dosya 100 MB'ı geçemez. Çok büyük kopyalar reddedilir.
- Pages saatte 10 yayın derlemesi yapar; art arda çok kopyalarsan sıraya girer.
- Depo herkese açıksa kopyalar da herkese açık olur. Telif sorumluluğu kullanıcıya aittir.
- Kopyalanan sayfaların form/API çağrıları çalışmaz (orijinal sunucu yok).
