# sitecopy

Bir web sitesini (sayfaları, stilleri, resimleri) indirip kendi bilgisayarında
gezilebilir hale getiren panel. Tamamı **tarayıcıda** çalışır: sunucu, hesap,
jeton, kurulum yok.

**Canlı panel:** <https://canxvar.github.io/sitecopy/>

## Nasıl çalışır

1. Adresi yaz, kaç sayfa kopyalanacağını seç, **Kopyala**'ya bas.
2. Panel sayfaları ve dosyaları indirir, bağlantıları göreli yollara çevirir.
3. Bitince `<alanadı>-sitecopy.zip` bilgisayarına iner.
4. ZIP'i aç, `index.html` dosyasına çift tıkla — site çevrimdışı açılır.

Site kopyaları hiçbir yere yüklenmez; her şey senin tarayıcında oluşur.

## Nasıl oluyor da tarayıcı başka siteleri okuyabiliyor

Normalde tarayıcı, başka bir alan adındaki dosyaları CORS yüzünden okuyamaz.
Panel bu yüzden okuma işini iki genel köprü üzerinden yapar:

| İçerik | Köprü |
|---|---|
| HTML, CSS, JS | `r.jina.ai` |
| Resimler (png/jpg/webp/gif/ico…) | `wsrv.nl` |

Sayfa adresleri, bağlantılar ve `url()` çağrıları kopya içinde yerelleştirilir;
indirilemeyen bir şey kalırsa tam adres olarak bırakılır.

## Kopyada ne olur, ne olmaz

- ✅ Sayfalar, stiller, resimler, menüler, statik içerik.
- ⚠️ Yazı tipleri (woff) indirilemez; sistem yazı tipine düşer.
- ⚠️ Site betikleri (JS) varsayılan olarak **çıkarılır**. Sebep: SPA siteler
  açılışta sayfayı kendi API'sinden yeniden kurar, çevrimdışı kopya boş kalır.
  İstersen **JS'i koru** kutusunu işaretleyebilirsin.
- ❌ Formlar, giriş, sepet, canlı arama gibi sunucu gerektiren şeyler çalışmaz.

## Sınırlar

- Sayfa başına ücretsiz köprülerin hız sınırı var; çok büyük siteler yavaşlar.
- Video, PDF, arşiv gibi ağır dosyalar kopyaya alınmaz.
- Kopyalanan sitelerin telif sorumluluğu kullanıcıya aittir.

## Yerel CLI (isteğe bağlı)

Panelin kullandığı motoru komut satırından da çalıştırabilirsin:

```bash
bundle install
ruby site_kopyala.rb https://ornek.com -o cikti -d 4 -s 40
```

## Dosyalar

| Yol | İş |
|---|---|
| `docs/index.html` | panel arayüzü |
| `docs/app.js` | tarayıcıdaki kopyalayıcı (indirme, yeniden yazma, ZIP) |
| `site_kopyala.rb` | aynı işi yapan Ruby CLI |
| `Gemfile` | CLI bağımlılıkları (`nokogiri`) |
