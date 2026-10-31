# sitecopy — online panel

`site_kopyala.rb` aracının web arayüzü (`kopya_sunucu.rb`). Tarayıcıdan bir URL
yapıştırırsın, site arka planda kopyalanır, ilerleme canlı akar ve bitince kopya
`/site/<kim>/` adresinde açılır.

Bu depo, paneli yerel makineden çıkarıp bir sunucuda (Docker) çalışacak hale
getirilmiş sürümüdür.

## Tek tıkla canlıya al

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/canxvar/sitecopy)

Render'da GitHub ile giriş yapıp **Apply** de; `KOPYA_SIFRE` otomatik üretilir.
Panel `https://<servis-adı>.onrender.com` adresinde, kullanıcı adı `admin`.

## Yerelde çalıştırma

```bash
bundle install
ruby kopya_sunucu.rb          # http://localhost:8787
```

Kopyalama yapabilmek için `nokogiri` gerekir (`bundle install` bunu kurar).

## Docker

```bash
docker build -t sitecopy .
docker run -p 8080:8080 -e KOPYA_KULLANICI=admin -e KOPYA_SIFRE=gizli sitecopy
```

## Sunucu modu

`KOPYA_MOD=sunucu` (veya tanımlı bir `PORT` değişkeni) sunucu modunu açar:

- `0.0.0.0` adresine bağlanır, `PORT` değişkenini kullanır.
- Kopyalar ayrı portlarda değil, `/site/<kim>/` altında tek adresten servis edilir.
- Kopyaların içindeki kök mutlak yollar (`/assets/x.css`) istek anında
  `/site/<kim>/assets/x.css` olarak yeniden yazılır.
- Chrome/Finder açma denemeleri yapılmaz.

## Ortam değişkenleri

| Değişken | Varsayılan | Açıklama |
|---|---|---|
| `KOPYA_MOD` | — | `sunucu` ise sunucu modu açılır |
| `PORT` | `8787` | Dinlenecek port (Render/Fly bunu kendisi verir) |
| `KOPYA_PORT` | `PORT` | Alternatif port değişkeni |
| `KOPYA_KOPYALAR` | `./kopyalar` | Kopyaların yazılacağı dizin |
| `KOPYA_KULLANICI` / `KOPYA_SIFRE` | — | İkisi de doluysa panel HTTP Basic ile korunur |
| `KOPYA_ACMA` | — | `0` ise açılışta tarayıcı açılmaz |

## Render'a dağıtım

Depo `render.yaml` içeriyor, yani "Blueprint" olarak tek tıkla kurulabilir:

1. Render → **New → Blueprint** → bu GitHub deposunu seç.
2. `KOPYA_SIFRE` otomatik üretilir; dashboard'daki **Environment** sekmesinden oku.
3. Panel `https://<servis-adı>.onrender.com` adresinde, kullanıcı adı `admin`.

## Sınırlar / uyarılar

- Render ücretsiz planında disk **geçicidir**: servis yeniden başlayınca kopyalar
  silinir. Kalıcılık için diskli (ücretli) plan veya S3 benzeri depo gerekir.
- Ücretsiz örnek 15 dakika trafik almazsa uyur, ilk istekte ~30 sn'de açılır.
- Panel herkese açık bir ayna servisi demektir: şifre korumasını açık tutun.
  Kopyalanan sitelerin telif sorumluluğu kullanıcıya aittir.
- Çok büyük siteler (GB mercii) ücretsiz örneğin diskini ve belleğini tüketir;
  `derinlik` değerini küçük tutun.
